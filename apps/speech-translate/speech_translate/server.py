import asyncio
from contextlib import asynccontextmanager, suppress
import json
import logging
from pathlib import Path
import secrets
import time
from urllib.parse import urlsplit

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .audio import SAMPLE_RATE, Segmenter
from .config import Settings
from .engine import Translator

STATIC = Path(__file__).resolve().parents[1] / "static"
LOGGER = logging.getLogger("speech_translate")
MAX_PACKET = SAMPLE_RATE * 2


class ProtocolError(Exception):
    def __init__(self, code: str, message: str, close_code=1008):
        self.code, self.message, self.close_code = code, message, close_code


def parse_control(text: str) -> dict:
    try:
        value = json.loads(text) if len(text) <= 4096 else None
    except (ValueError, RecursionError):
        value = None
    if not isinstance(value, dict):
        raise ProtocolError("invalid_control", "Send a JSON object of at most 4096 characters.")
    return value


def origin_allowed(ws: WebSocket, settings: Settings) -> bool:
    origin = ws.headers.get("origin")
    if origin is None:
        return True
    if settings.allowed_origins:
        return origin in settings.allowed_origins
    expected_scheme = "https" if ws.url.scheme == "wss" else "http"
    try:
        parsed = urlsplit(origin)
        return (parsed.scheme == expected_scheme and parsed.netloc == ws.headers.get("host")
                and not parsed.path and not parsed.query and not parsed.fragment)
    except ValueError:
        return False


class AudioBudget:
    def __init__(self):
        self.available = MAX_PACKET * 2.0
        self.updated = time.monotonic()

    def take(self, size: int):
        now = time.monotonic()
        self.available = min(MAX_PACKET * 2.0, self.available + (now - self.updated) * MAX_PACKET)
        self.updated = now
        if size > self.available:
            raise ProtocolError("audio_rate_exceeded", "Pace audio in real time; burst allowance is two seconds.")
        self.available -= size


async def run_session(ws, translator, settings, segmenter, send):
    queue = asyncio.Queue(maxsize=settings.queue_size)
    budget = AudioBudget()

    def enqueue(items):
        if len(items) > queue.maxsize - queue.qsize():
            raise ProtocolError("overloaded", "Translation queue is full. Stop and reconnect later.", 1013)
        for item in items:
            queue.put_nowait(item)

    async def receive_audio():
        while True:
            try:
                message = await asyncio.wait_for(ws.receive(), settings.idle_seconds)
            except asyncio.TimeoutError:
                raise ProtocolError("idle_timeout", "No audio or control received before the idle timeout.") from None
            if message["type"] == "websocket.disconnect":
                raise WebSocketDisconnect(message.get("code", 1000))
            pcm = message.get("bytes")
            if pcm is not None:
                if not pcm or len(pcm) > MAX_PACKET or len(pcm) % 2:
                    raise ProtocolError("invalid_audio", "Send 1–16000 complete PCM16 samples per binary message.")
                budget.take(len(pcm))
                enqueue(segmenter.feed(pcm))
                continue
            control = parse_control(message.get("text", ""))
            if control not in ({"type": "flush"}, {"type": "stop"}):
                raise ProtocolError("invalid_control", "Expected flush or stop.")
            enqueue(segmenter.flush())
            if control["type"] == "stop":
                # 중지 응답은 큐에 남은 마지막 발화까지 전송한 뒤에만 보낸다.
                await queue.put(None)
                return

    async def translate_audio():
        sequence = 0
        while True:
            utterance = await queue.get()
            if utterance is None:
                await send({"type": "stopped", "segments": sequence})
                return
            started = time.monotonic()
            text = await translator.translate(utterance.pcm)
            sequence += 1
            await send({
                "type": "translation", "id": sequence, "text": text, "final": True,
                "source_language": "ko", "target_language": "en",
                "start_ms": round(utterance.start * 1000),
                "end_ms": round(utterance.end * 1000),
                "processing_ms": round((time.monotonic() - started) * 1000),
            })

    reader = asyncio.create_task(receive_audio())
    worker = asyncio.create_task(translate_audio())
    try:
        done, _ = await asyncio.wait({reader, worker}, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
        await asyncio.gather(reader, worker)
    finally:
        reader.cancel()
        worker.cancel()
        await asyncio.gather(reader, worker, return_exceptions=True)


def create_app(settings=None, translator=None, segmenter_factory=None):
    @asynccontextmanager
    async def lifespan(app):
        app.state.settings = settings or Settings.from_env()
        app.state.translator = translator or Translator(app.state.settings)
        app.state.sessions = 0
        app.state.ready = False
        try:
            await app.state.translator.load()
            app.state.ready = True
            yield
        finally:
            app.state.ready = False
            await app.state.translator.close()

    app = FastAPI(title="Korean → English speech translation", lifespan=lifespan,
                  docs_url=None, redoc_url=None)

    @app.middleware("http")
    async def headers(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Permissions-Policy"] = "microphone=(self)"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; "
            "base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        )
        return response

    @app.get("/healthz")
    async def health():
        return {"status": "ok"}

    @app.get("/readyz")
    async def ready():
        from fastapi.responses import JSONResponse

        is_ready = getattr(app.state, "ready", False)
        return JSONResponse({"ready": is_ready}, status_code=200 if is_ready else 503)

    @app.get("/", include_in_schema=False)
    async def index():
        return FileResponse(STATIC / "index.html")

    app.mount("/static", StaticFiles(directory=STATIC), name="static")

    @app.websocket("/v1/translate")
    async def translate(ws: WebSocket):
        cfg = app.state.settings
        if not origin_allowed(ws, cfg):
            await ws.close(code=1008)
            return
        if app.state.sessions >= cfg.max_sessions:
            await ws.accept()
            with suppress(Exception):
                await asyncio.wait_for(ws.send_json({"type": "error", "code": "busy",
                                                    "message": "All translation sessions are in use."}), cfg.send_seconds)
            await ws.close(code=1013)
            return
        app.state.sessions += 1

        async def send(data):
            await asyncio.wait_for(ws.send_json(data), cfg.send_seconds)

        try:
            await ws.accept()
            try:
                message = await asyncio.wait_for(ws.receive(), cfg.auth_seconds)
            except asyncio.TimeoutError:
                raise ProtocolError("auth_timeout", "Send start within ten seconds.") from None
            if message["type"] == "websocket.disconnect":
                return
            start = parse_control(message.get("text") or "")
            token = start.get("token")
            if not isinstance(token, str) or not secrets.compare_digest(token.encode(), cfg.token.encode()):
                raise ProtocolError("unauthorized", "Invalid API token.")
            if (set(start) != {"type", "token", "sample_rate", "format"}
                    or start["type"] != "start" or start["sample_rate"] != SAMPLE_RATE
                    or start["format"] != "pcm_s16le"):
                raise ProtocolError("invalid_start", "Expected start with sample_rate=16000 and format=pcm_s16le (mono).")
            if segmenter_factory:
                segmenter = segmenter_factory()
            else:
                import webrtcvad

                vad = webrtcvad.Vad(2)
                segmenter = Segmenter(lambda frame: vad.is_speech(frame, SAMPLE_RATE),
                                      silence_ms=cfg.silence_ms, max_utterance_ms=cfg.max_utterance_ms)
            await send({"type": "ready", "sample_rate": SAMPLE_RATE, "channels": 1,
                        "format": "pcm_s16le", "silence_ms": cfg.silence_ms,
                        "max_utterance_ms": cfg.max_utterance_ms,
                        "session_seconds": cfg.session_seconds})
            try:
                await asyncio.wait_for(run_session(ws, app.state.translator, cfg, segmenter, send),
                                       cfg.session_seconds)
            except asyncio.TimeoutError:
                raise ProtocolError("timeout", "Session duration or output timeout exceeded.") from None
            await ws.close(code=1000)
        except ProtocolError as error:
            with suppress(Exception):
                await send({"type": "error", "code": error.code, "message": error.message})
                await ws.close(code=error.close_code)
        except WebSocketDisconnect:
            pass
        except Exception as error:
            # 오디오·토큰·모델 예외 원문에는 사용자 자료가 있을 수 있으므로 기록하지 않는다.
            LOGGER.error("Translation session failed (%s)", type(error).__name__)
            with suppress(Exception):
                await send({"type": "error", "code": "inference_failed", "message": "Translation failed. Check server health."})
                await ws.close(code=1011)
        finally:
            app.state.sessions -= 1

    return app


app = create_app()
