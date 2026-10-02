FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HF_HOME=/models/huggingface \
    SPEECH_MODEL_DIR=/models \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/venv \
    && useradd --uid 10001 --create-home app \
    && mkdir /models && chown app:app /models

WORKDIR /app
COPY requirements*.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY speech_translate ./speech_translate
COPY static ./static
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/readyz', timeout=3)"
# 프로세스를 늘리면 모델과 세션 제한도 복제되므로 GPU당 한 worker만 실행한다.
CMD ["uvicorn", "speech_translate.server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--ws", "websockets", "--ws-max-size", "32768", "--ws-max-queue", "4", "--ws-per-message-deflate", "false", "--no-access-log", "--timeout-graceful-shutdown", "30"]
