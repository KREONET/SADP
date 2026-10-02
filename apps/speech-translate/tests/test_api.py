import asyncio
import importlib.util
import threading
import unittest
from unittest.mock import patch

from speech_translate.audio import Utterance
from speech_translate.config import Settings
from speech_translate.engine import Translator
from test_audio import VOICE, SILENCE, segmenter

HAS_API = all(importlib.util.find_spec(name) is not None for name in ("fastapi", "httpx", "webrtcvad"))
if HAS_API:
    from fastapi.testclient import TestClient
    from starlette.websockets import WebSocketDisconnect
    from speech_translate.server import AudioBudget, ProtocolError, create_app, parse_control

TOKEN = "test-only-placeholder-credential-32-chars"
START = {"type": "start", "token": TOKEN, "sample_rate": 16000, "format": "pcm_s16le"}


class FakeTranslator:
    def __init__(self, fail=False):
        self.calls = []
        self.fail = fail
        self.closed = False

    async def load(self):
        pass

    async def close(self):
        self.closed = True

    async def translate(self, pcm):
        self.calls.append(pcm)
        if self.fail:
            raise RuntimeError("sensitive exception must not reach clients")
        return "Hello, this is a translation."


@unittest.skipUnless(HAS_API, "[SKIP] API dependencies missing; install requirements-test.txt")
class ApiTests(unittest.TestCase):
    def client(self, *, translator=None, factory=segmenter, **settings):
        return TestClient(create_app(Settings(token=TOKEN, **settings), translator or FakeTranslator(), factory))

    def start(self, ws):
        ws.send_json(START)
        self.assertEqual(ws.receive_json()["type"], "ready")

    def test_ui_and_health(self):
        translator = FakeTranslator()
        with self.client(translator=translator) as client:
            self.assertEqual(client.get("/readyz").json(), {"ready": True})
            self.assertEqual(client.get("/healthz").status_code, 200)
            self.assertIn("마이크", client.get("/").text)
            self.assertIn("frame-ancestors 'none'", client.get("/").headers["content-security-policy"])
            self.assertEqual(client.get("/static/recorder.js").status_code, 200)
            self.assertIn("javascript", client.get("/static/pcm.mjs").headers["content-type"])
        self.assertTrue(translator.closed)

    def test_translation_then_stop_drains_final_audio(self):
        translator = FakeTranslator()
        with self.client(translator=translator) as client, client.websocket_connect("/v1/translate") as ws:
            self.start(ws)
            ws.send_bytes(VOICE * 10 + SILENCE * 20)
            first = ws.receive_json()
            self.assertEqual(first["text"], "Hello, this is a translation.")
            self.assertEqual(first["id"], 1)
            ws.send_bytes(VOICE * 10 + VOICE[:100])
            ws.send_json({"type": "stop"})
            last = ws.receive_json()
            self.assertEqual(last["id"], 2)
            self.assertEqual(last["end_ms"], 1203)
            self.assertEqual(ws.receive_json(), {"type": "stopped", "segments": 2})
            self.assertEqual(translator.calls[-1], VOICE * 10 + VOICE[:100])

    def test_auth_and_protocol_validation(self):
        for payload, code in ((dict(START, token="bad"), "unauthorized"),
                              (dict(START, sample_rate=48000), "invalid_start"),
                              (dict(START, format="webm"), "invalid_start"),
                              ([], "invalid_control")):
            with self.subTest(code=code), self.client() as client, client.websocket_connect("/v1/translate") as ws:
                ws.send_json(payload)
                self.assertEqual(ws.receive_json()["code"], code)

    def test_audio_before_auth_is_rejected(self):
        with self.client() as client, client.websocket_connect("/v1/translate") as ws:
            ws.send_bytes(VOICE)
            self.assertEqual(ws.receive_json()["code"], "invalid_control")

    def test_disallowed_origin_and_explicit_allowlist(self):
        with self.client() as client:
            with self.assertRaises(WebSocketDisconnect):
                with client.websocket_connect("/v1/translate", headers={"origin": "https://untrusted.invalid"}):
                    pass
        with self.client(allowed_origins=("https://ui.example.invalid",)) as client:
            with client.websocket_connect("/v1/translate", headers={"origin": "https://ui.example.invalid"}) as ws:
                self.start(ws)
                ws.send_json({"type": "stop"})
                self.assertEqual(ws.receive_json()["type"], "stopped")

    def test_same_origin_browser_can_connect(self):
        with self.client() as client, client.websocket_connect("/v1/translate", headers={"origin": "http://testserver"}) as ws:
            self.start(ws)
            ws.send_json({"type": "stop"})
            self.assertEqual(ws.receive_json()["type"], "stopped")

    def test_invalid_binary_sizes(self):
        for data in (b"", b"x", bytes(32002)):
            with self.subTest(size=len(data)), self.client() as client, client.websocket_connect("/v1/translate") as ws:
                self.start(ws)
                ws.send_bytes(data)
                self.assertEqual(ws.receive_json()["code"], "invalid_audio")

    def test_busy_and_disconnect_release_capacity(self):
        with self.client(max_sessions=1) as client:
            with client.websocket_connect("/v1/translate") as first:
                self.start(first)
                with client.websocket_connect("/v1/translate") as second:
                    self.assertEqual(second.receive_json()["code"], "busy")
            with client.websocket_connect("/v1/translate") as next_ws:
                self.start(next_ws)
                next_ws.send_json({"type": "stop"})
                self.assertEqual(next_ws.receive_json()["type"], "stopped")

    def test_auth_and_idle_timeouts(self):
        with self.client(auth_seconds=0.02) as client, client.websocket_connect("/v1/translate") as ws:
            self.assertEqual(ws.receive_json()["code"], "auth_timeout")
        with self.client(idle_seconds=0.02) as client, client.websocket_connect("/v1/translate") as ws:
            self.start(ws)
            self.assertEqual(ws.receive_json()["code"], "idle_timeout")

    def test_inference_failure_is_sanitized(self):
        with self.client(translator=FakeTranslator(fail=True)) as client, client.websocket_connect("/v1/translate") as ws:
            self.start(ws)
            ws.send_bytes(VOICE * 10)
            ws.send_json({"type": "stop"})
            error = ws.receive_json()
            self.assertEqual(error["code"], "inference_failed")
            self.assertNotIn("sensitive", str(error))

    def test_queue_overflow_is_explicit(self):
        class ManySegments:
            def feed(self, pcm):
                return [Utterance(pcm, 0, 1)] * 3

        with self.client(factory=ManySegments, queue_size=2) as client, client.websocket_connect("/v1/translate") as ws:
            self.start(ws)
            ws.send_bytes(VOICE)
            self.assertEqual(ws.receive_json()["code"], "overloaded")

    def test_receiver_stays_active_during_inference(self):
        started = threading.Event()

        class SlowTranslator(FakeTranslator):
            async def translate(self, pcm):
                started.set()
                await asyncio.sleep(10)
                return "too late"

        with self.client(translator=SlowTranslator(), session_seconds=1) as client, client.websocket_connect("/v1/translate") as ws:
            self.start(ws)
            ws.send_bytes(VOICE * 10 + SILENCE * 20)
            self.assertTrue(started.wait(1))
            ws.send_json({"type": "unknown"})
            self.assertEqual(ws.receive_json()["code"], "invalid_control")

    def test_real_vad_does_not_translate_silence(self):
        translator = FakeTranslator()
        with self.client(translator=translator, factory=None) as client, client.websocket_connect("/v1/translate") as ws:
            self.start(ws)
            ws.send_bytes(bytes(32000))
            ws.send_json({"type": "stop"})
            self.assertEqual(ws.receive_json(), {"type": "stopped", "segments": 0})
        self.assertEqual(translator.calls, [])

    def test_controls_and_rate_limit(self):
        for text in ("[]", "null", "{", "x" * 4097, "[" * 10000):
            with self.assertRaises(ProtocolError):
                parse_control(text)
        with patch("speech_translate.server.time.monotonic", return_value=1):
            budget = AudioBudget()
            budget.take(64000)
            with self.assertRaises(ProtocolError):
                budget.take(2)


class EngineTests(unittest.IsolatedAsyncioTestCase):
    async def test_cancelled_request_holds_gpu_slot_until_inference_finishes(self):
        translator = Translator(Settings(token=TOKEN))
        began = threading.Event()
        release = threading.Event()
        calls = []

        def blocking(pcm):
            calls.append(pcm)
            began.set()
            if not release.wait(3):
                raise TimeoutError("Test worker not released")
            return "done"

        translator._translate = blocking
        first = asyncio.create_task(translator.translate(b"first"))
        second = None
        try:
            self.assertTrue(await asyncio.to_thread(began.wait, 1))
            first.cancel()
            second = asyncio.create_task(translator.translate(b"second"))
            await asyncio.sleep(0.02)
            self.assertEqual(calls, [b"first"])
            release.set()
            with self.assertRaises(asyncio.CancelledError):
                await first
            self.assertEqual(await second, "done")
            self.assertEqual(calls, [b"first", b"second"])
        finally:
            release.set()
            await asyncio.gather(first, *([second] if second else []), return_exceptions=True)
            await translator.close()
