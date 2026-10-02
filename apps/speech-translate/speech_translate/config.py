from dataclasses import dataclass, field
import os


@dataclass(frozen=True)
class Settings:
    token: str = field(repr=False)
    model: str = "large-v3"
    device: str = "cuda"
    compute_type: str = "float16"
    model_dir: str = "/models"
    offline: bool = False
    allowed_origins: tuple[str, ...] = ()
    max_sessions: int = 2
    queue_size: int = 2
    silence_ms: int = 600
    max_utterance_ms: int = 6000
    idle_seconds: float = 15
    session_seconds: float = 1800
    auth_seconds: float = 10
    send_seconds: float = 10

    def __post_init__(self):
        if len(self.token) < 32:
            raise ValueError("SPEECH_API_TOKEN must contain at least 32 characters")
        if self.device not in {"cuda", "cpu"}:
            raise ValueError("SPEECH_DEVICE must be cuda or cpu")
        if not 1 <= self.max_sessions <= 16 or not 1 <= self.queue_size <= 8:
            raise ValueError("Session or queue limit is out of range")
        if not 300 <= self.silence_ms <= 1500:
            raise ValueError("SPEECH_SILENCE_MS must be between 300 and 1500")
        if not 1500 <= self.max_utterance_ms <= 15000:
            raise ValueError("SPEECH_MAX_UTTERANCE_MS must be between 1500 and 15000")
        if min(self.idle_seconds, self.session_seconds, self.auth_seconds, self.send_seconds) <= 0:
            raise ValueError("Timeouts must be positive")
        if self.model.endswith(".en") or "turbo" in self.model.lower() or "distil" in self.model.lower():
            raise ValueError("Use a multilingual translation model, such as large-v3")

    @classmethod
    def from_env(cls):
        return cls(
            token=os.environ.get("SPEECH_API_TOKEN", ""),
            model=os.environ.get("SPEECH_MODEL", "large-v3"),
            device=os.environ.get("SPEECH_DEVICE", "cuda"),
            compute_type=os.environ.get("SPEECH_COMPUTE_TYPE", "float16"),
            model_dir=os.environ.get("SPEECH_MODEL_DIR", "/models"),
            offline=os.environ.get("SPEECH_OFFLINE", "false").lower() == "true",
            allowed_origins=tuple(x.strip() for x in os.environ.get("SPEECH_ALLOWED_ORIGINS", "").split(",") if x.strip()),
            max_sessions=int(os.environ.get("SPEECH_MAX_SESSIONS", "2")),
            queue_size=int(os.environ.get("SPEECH_QUEUE_SIZE", "2")),
            silence_ms=int(os.environ.get("SPEECH_SILENCE_MS", "600")),
            max_utterance_ms=int(os.environ.get("SPEECH_MAX_UTTERANCE_MS", "6000")),
        )
