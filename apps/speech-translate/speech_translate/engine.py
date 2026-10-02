import asyncio
from concurrent.futures import ThreadPoolExecutor
from functools import partial

from .config import Settings


class Translator:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="speech-inference")
        self.lock = asyncio.Lock()
        self.model = None

    async def load(self):
        from faster_whisper import WhisperModel

        settings = self.settings
        self.model = await asyncio.get_running_loop().run_in_executor(
            self.pool, partial(WhisperModel, settings.model, device=settings.device,
                               compute_type=settings.compute_type, download_root=settings.model_dir,
                               local_files_only=settings.offline, cpu_threads=4, num_workers=1)
        )
        # CUDA 라이브러리 누락을 첫 사용자 요청까지 숨기지 않는다.
        await self.translate(bytes(16000 * 2))

    def _translate(self, pcm: bytes) -> str:
        import numpy as np

        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        segments, _ = self.model.transcribe(
            audio, language="ko", task="translate", beam_size=1,
            temperature=0.0, condition_on_previous_text=False,
            without_timestamps=True, vad_filter=False,
        )
        # generator 순회를 worker 안에서 끝내야 이벤트 루프가 GPU 추론에 막히지 않는다.
        return " ".join(segment.text.strip() for segment in segments if segment.text.strip())

    async def translate(self, pcm: bytes) -> str:
        async with self.lock:
            future = asyncio.get_running_loop().run_in_executor(self.pool, self._translate, pcm)
            try:
                return await asyncio.shield(future)
            except asyncio.CancelledError:
                # 소켓 취소로 CUDA 작업은 중단되지 않는다. 실제 종료까지 슬롯을 유지한다.
                try:
                    await future
                finally:
                    raise

    async def close(self):
        await asyncio.to_thread(self.pool.shutdown, wait=True, cancel_futures=True)
