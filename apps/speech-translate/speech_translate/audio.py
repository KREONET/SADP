from collections import deque
from dataclasses import dataclass
from typing import Callable

SAMPLE_RATE = 16000
FRAME_SAMPLES = 480
FRAME_BYTES = FRAME_SAMPLES * 2


@dataclass(frozen=True)
class Utterance:
    pcm: bytes
    start: float
    end: float


class Segmenter:
    def __init__(self, is_speech: Callable[[bytes], bool], *, silence_ms=600,
                 max_utterance_ms=6000, min_speech_ms=240):
        self.is_speech = is_speech
        self.silence_samples = silence_ms * SAMPLE_RATE // 1000
        self.max_samples = max_utterance_ms * SAMPLE_RATE // 1000
        self.min_speech_samples = min_speech_ms * SAMPLE_RATE // 1000
        self.pending = bytearray()
        self.pre_roll = deque(maxlen=10)
        self.active = bytearray()
        self.position = 0
        self.start = 0
        self.voiced = 0
        self.silence = 0

    def feed(self, pcm: bytes) -> list[Utterance]:
        if len(pcm) % 2:
            raise ValueError("PCM16 requires complete two-byte samples")
        self.pending.extend(pcm)
        output = []
        while len(self.pending) >= FRAME_BYTES:
            frame = bytes(self.pending[:FRAME_BYTES])
            del self.pending[:FRAME_BYTES]
            utterance = self._frame(frame)
            if utterance is not None:
                output.append(utterance)
        return output

    def _frame(self, frame: bytes) -> Utterance | None:
        samples = len(frame) // 2
        # 마지막 패킷도 VAD에 넣되, 패딩이 오디오 시각을 늘리지 않게 한다.
        speech = self.is_speech(frame.ljust(FRAME_BYTES, b"\x00"))
        if not self.active:
            if not speech:
                self.pre_roll.append(frame)
                self.position += samples
                return None
            self.active.extend(b"".join(self.pre_roll))
            self.pre_roll.clear()
            self.start = self.position - len(self.active) // 2
        self.active.extend(frame)
        self.position += samples
        if speech:
            self.voiced += samples
            self.silence = 0
        else:
            self.silence += samples
        if self.silence >= self.silence_samples or len(self.active) // 2 >= self.max_samples:
            return self._emit()
        return None

    def _emit(self) -> Utterance | None:
        output = None
        if self.voiced >= self.min_speech_samples:
            output = Utterance(bytes(self.active), self.start / SAMPLE_RATE,
                               self.position / SAMPLE_RATE)
        self.active.clear()
        self.voiced = self.silence = 0
        return output

    def flush(self) -> list[Utterance]:
        output = []
        if self.pending:
            utterance = self._frame(bytes(self.pending))
            self.pending.clear()
            if utterance is not None:
                output.append(utterance)
        utterance = self._emit()
        if utterance is not None:
            output.append(utterance)
        self.pre_roll.clear()
        return output
