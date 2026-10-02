# 한국어 음성 → 영어 텍스트

브라우저 마이크 → WebSocket PCM → WebRTC VAD → A6000의 faster-whisper `large-v3` → 영어 텍스트 순서로 동작한다.
브라우저 화면과 API는 같은 서버에서 제공한다. 모델 추론은 로컬에서 수행하며 외부 번역 API를 호출하지 않는다.
처음 시작할 때 공개 모델을 다운로드하고 이후에는 Docker volume의 캐시를 사용한다.

단어가 들어올 때마다 다시 쓰는 자막이 아니라 **발화 단위의 확정 결과**를 보낸다.
기본값은 600ms 무음 또는 최대 6초 입력에서 발화를 끊는다. 체감 지연에는 이 대기와 큐 대기·추론·네트워크 시간이 더해진다.
6초 경계가 문장 중간에 걸리면 번역 문맥이 잘릴 수 있다. `SPEECH_MAX_UTTERANCE_MS`를 늘리면 문맥은 길어지지만 지연도 늘어난다.
잡음·매우 짧은 말·고유명사에 대한 인식 오류와 무음 오인식 가능성이 있으며, 실제 한국어 자료로 품질을 확인해야 한다.
A6000에서의 번역 정확도·지연·동시 처리량은 해당 서버에서 측정해야 한다.

## A6000 서버에서 실행

Linux, CUDA 12.8 컨테이너와 호환되는 NVIDIA 드라이버, Docker Compose, NVIDIA Container Toolkit이 필요하다.
호스트에서 `nvidia-smi`가 동작해야 한다. GPU 하나에 서버 프로세스 하나를 사용한다.
기본 선택은 GPU index 0이며 여러 장이면 `SPEECH_GPU_ID`를 A6000의 index 또는 GPU UUID로 지정한다.

저장소 루트의 Bash에서 실행한다. 토큰은 32자 이상의 무작위 값을 준비해 입력한다.
토큰을 이미지나 Git 파일에 넣지 않는다. 아래 명령은 기존 프로세스 환경변수를 사용하며 `.env` 파일을 읽지 않는다.

```bash
read -r -s -p 'API token: ' SPEECH_API_TOKEN
export SPEECH_API_TOKEN
docker compose --env-file /dev/null -f apps/speech-translate/compose.yaml up --build -d
docker compose --env-file /dev/null -f apps/speech-translate/compose.yaml ps
docker compose --env-file /dev/null -f apps/speech-translate/compose.yaml logs --tail=80
```

첫 다운로드는 수 분 이상 걸릴 수 있다. 모델 로드와 CUDA warm-up이 끝난 뒤 요청을 받는다.
컨테이너 health가 `healthy`이면 브라우저에서 localhost의 8000 포트를 열고 같은 토큰을 입력한다.
`마이크 켜고 번역 시작`을 누른 뒤 한국어로 말한다. `종료`는 마지막 발화와 대기 중 번역까지 받은 뒤 연결을 닫는다.

서버가 원격이면 워크스테이션에서 터널을 연 다음 워크스테이션의 localhost 8000 포트로 접속한다.

```bash
ssh -N -L 8000:localhost:8000 <GPU_SERVER_USER>@<GPU_SERVER_HOST>
```

Compose는 기본적으로 호스트의 loopback에만 포트를 공개한다. 원격 서비스로 공개할 때는 HTTPS/WSS reverse proxy를 앞에 둔다.
브라우저 마이크는 HTTPS 또는 localhost의 secure context가 필요하다. proxy는 WebSocket upgrade를 전달하고
stream timeout을 충분히 길게 설정해야 한다. TLS proxy 뒤에서는 외부 origin을 `SPEECH_ALLOWED_ORIGINS`에 정확히 지정한다.
예: `https://<SPEECH_HOST>` (경로와 끝 `/` 없이). 기본 origin 검사는 요청과 같은 scheme/host/port만 허용한다.
웹 화면에서 토큰을 입력하므로 공유 토큰을 공개 JavaScript에 하드코딩하지 않는다.

중지:

```bash
docker compose --env-file /dev/null -f apps/speech-translate/compose.yaml down
```

## WebSocket API

주소는 `wss://<SPEECH_HOST>/v1/translate`다. 로컬 터널에서는 `ws://<LOCAL_HOST>:8000/v1/translate`를 사용한다.
오디오 업로드와 결과 수신은 **동시에** 수행한다. 브라우저 예제는 [static/app.js](static/app.js)에 있다.

1. 연결 후 10초 안에 JSON `start`를 보낸다. token은 URL/query가 아닌 첫 메시지에 담는다.

```json
{"type":"start","token":"<API_TOKEN>","sample_rate":16000,"format":"pcm_s16le"}
```

2. 서버의 `ready` 이후 binary 메시지로 **16kHz, mono, signed 16-bit little-endian PCM**을 보낸다.
   권장 packet은 20ms(640 bytes)다. 한 메시지는 2~32000 bytes이고 2의 배수여야 한다.
   WAV 헤더, WebM/Opus, base64는 보내지 않는다. 브라우저 AudioWorklet은 장치의 44.1/48kHz 입력을 16kHz로 변환한다.
   파일 업로드도 실시간 속도로 전송한다. 서버는 최대 2초 burst만 허용한다.

```json
{"type":"ready","sample_rate":16000,"channels":1,"format":"pcm_s16le","silence_ms":600,"max_utterance_ms":6000,"session_seconds":1800}
```

3. 확정 결과가 입력 오디오 순서대로 도착한다. `id`는 연결마다 1부터 시작한다.
   `start_ms`/`end_ms`는 해당 연결의 PCM 시작점을 기준으로 한 입력 발화 경계이며 단어별 timestamp가 아니다.
   `processing_ms`는 서버가 그 발화를 처리하기 시작한 뒤 GPU 순서 대기와 추론에 쓴 시간이다.
   세션 큐 대기·발화 구간화·네트워크 시간은 포함하지 않으므로 전체 지연으로 해석하지 않는다.
   모델이 텍스트를 반환하지 않으면 `text`가 빈 문자열인 결과도 올 수 있다.

```json
{"type":"translation","id":1,"text":"Hello, nice to meet you.","final":true,"source_language":"ko","target_language":"en","start_ms":0,"end_ms":1800,"processing_ms":420}
```

위 시간과 문장은 프로토콜 예시이며 측정치가 아니다.

4. 강제로 현재 발화를 확정하고 계속 입력하려면 `{"type":"flush"}`를 보낸다.
   끝내려면 마지막 PCM 패킷을 보낸 후 `{"type":"stop"}`을 보내고 `stopped`까지 기다린다.
   `flush`/`stop`에서도 음성으로 판단된 구간이 240ms 미만이면 버린다.

```json
{"type":"stopped","segments":1}
```

오류는 `{"type":"error","code":"overloaded","message":"..."}` 후 연결 종료로 전달된다.
`busy`는 세션 한도, `overloaded`는 발화 큐 한도, `audio_rate_exceeded`는 입력 속도 초과,
`unauthorized`는 토큰 오류, `invalid_start`/`invalid_control`/`invalid_audio`는 프로토콜 오류다.
`auth_timeout`/`idle_timeout`/`timeout`은 제한 시간, `inference_failed`는 추론 또는 서버 처리 실패다.
오류나 비정상 종료에는 완료되지 않은 결과가 있을 수 있다. 새 연결은 새 세션이며 자동 재전송·이어받기는 하지 않는다.
허용되지 않은 browser origin은 WebSocket upgrade 전에 거부된다.

Python WAV 클라이언트도 포함한다. 아래 개발과 검사 절의 venv와 `requirements-test.txt`를 준비한다.
16kHz mono PCM16 WAV와 토큰 환경변수를 준비한 다음 실행한다.

```bash
apps/speech-translate/.venv/bin/python apps/speech-translate/client.py --url 'wss://<SPEECH_HOST>/v1/translate' --wav '<KOREAN_WAV_PATH>'
```

## 설정과 자원 제한

| 환경변수 | 기본값 | 의미 |
|---|---|---|
| `SPEECH_API_TOKEN` | 필수 | 32자 이상, 서버 런타임에만 공급 |
| `SPEECH_GPU_ID` | `0` | Compose가 컨테이너에 노출할 GPU |
| `SPEECH_MODEL` | `large-v3` | 다국어 번역 모델 이름 또는 로컬 CTranslate2 모델 경로 |
| `SPEECH_COMPUTE_TYPE` | `float16` | VRAM을 줄이려면 `int8_float16`로 실측 비교 |
| `SPEECH_MAX_SESSIONS` | `2` | 인증 대기 포함 동시 연결 수, 범위 1~16 |
| `SPEECH_QUEUE_SIZE` | `2` | 세션별 대기 발화 수, 범위 1~8 |
| `SPEECH_SILENCE_MS` | `600` | 발화 확정 무음 길이, 범위 300~1500 |
| `SPEECH_MAX_UTTERANCE_MS` | `6000` | 최대 발화 길이, 범위 1500~15000 (30ms 단위로 처리) |
| `SPEECH_ALLOWED_ORIGINS` | 빈 값 | 빈 값은 same-origin, 지정 시 쉼표로 구분한 정확 일치 목록 |
| `SPEECH_OFFLINE` | `false` | 모델 캐시 준비 후 `true`로 다운로드 없이 시작 |
| `SPEECH_BIND_ADDRESS` | loopback | Compose host bind 주소 |
| `SPEECH_PORT` | `8000` | Compose host port |

GPU 추론은 하나씩 실행한다. 세션마다 진행 중 1개와 제한된 대기 큐만 보유하고, 초과 시 오류로 종료한다.
클라이언트가 끊어져도 이미 시작된 GPU 연산은 끝까지 슬롯을 차지한다. 끊어진 연결의 새 작업은 실행하지 않는다.
기본 세션 길이는 30분, 입력 idle timeout은 15초다. 마이크는 무음도 계속 PCM으로 보내야 한다.
브라우저 출력은 최근 200개 결과만 유지한다. 서버는 음성·번역·토큰을 파일이나 접근 로그에 저장하지 않는다.
프록시/외부 로깅 계층의 별도 저장 설정까지 제어하지는 않는다.

`turbo`는 번역용으로 학습되지 않았고 `.en`/영어 전용 distil 모델은 한국어 번역에 맞지 않아 설정에서 거부한다.
[Whisper 모델 안내](https://github.com/openai/whisper#available-models-and-languages)와
[faster-whisper CUDA 요구사항](https://github.com/SYSTRAN/faster-whisper#gpu)을 따른다.

## 개발과 검사

Python 3.12 이상을 사용한다. API 시험은 모델을 다운로드하거나 GPU를 사용하지 않는다.
추론을 fake로 대체하고 패킷 분할·인증·origin·큐·종료·취소를 검증한다. 실제 WebRTC VAD의 무음 처리도 검사한다.

```bash
python3 -m venv apps/speech-translate/.venv
apps/speech-translate/.venv/bin/python -m pip install -r apps/speech-translate/requirements-test.txt
apps/speech-translate/.venv/bin/python scripts/tests/speech-translate-test.py
bash ./sadp --test
```

`bash ./sadp --test`는 이 시험을 자동 포함한다. API 의존성이 없는 환경에서는 해당 시험을 `[SKIP]`으로 알린다.
CI는 `requirements-test.txt`를 설치해 API 시험도 실행한다. Node.js가 없으면 브라우저 리샘플러 시험은 `[SKIP]`이다.

Docker 없이 실제 모델을 실행하려면 `requirements.txt`와 CUDA/cuDNN을 준비한 뒤 앱 디렉터리에서 시작한다.
`SPEECH_DEVICE=cpu`, `SPEECH_COMPUTE_TYPE=int8`는 CPU smoke test용이며 A6000 성능을 나타내지 않는다.

```bash
apps/speech-translate/.venv/bin/python -m pip install -r apps/speech-translate/requirements.txt
cd apps/speech-translate
export SPEECH_MODEL_DIR="$PWD/models"
.venv/bin/uvicorn speech_translate.server:app --host 127.0.0.1 --port 8000 --workers 1 --ws websockets --ws-max-size 32768 --ws-max-queue 4 --ws-per-message-deflate false --no-access-log
```

실제 수용 검사는 A6000에서 모델을 기동한 후 한국어 WAV와 브라우저 마이크로 수행한다.
의미 보존, 무음 환각, 긴 문장 경계, 마지막 발화 수신, 처리 시간과 입력 길이를 비교한다.
동시 세션 수는 대표 입력에서 큐가 누적되지 않는 범위로 조정한다. GPU가 없는 API 시험만으로 성능을 보증하지 않는다.

## SADP 배포 경계

이 앱은 독립 실행용 Docker 구성을 제공한다. 기존 사이트 계약·생성물·Portal·Argo CD 등록은 변경하지 않는다.
RKE2에 편입할 때는 NVIDIA device plugin/runtime과 GPU node 배치가 먼저 준비되어야 한다.
GPU request/limit `nvidia.com/gpu: 1`, 단일 replica/worker, 모델 캐시 volume, WebSocket 경로와 timeout을 설정한다.
클러스터용 `SPEECH_API_TOKEN`은 OpenBao → ESO → ExternalSecret으로 런타임에 주입한다.
차트가 Kubernetes Secret을 직접 만들거나 공통 Portal 빌드용 `.env`로 전달하면 안 된다.
모델 다운로드가 막힌 사이트에서는 캐시를 미리 채운 뒤 `SPEECH_OFFLINE=true`로 운용한다.
