"""16kHz mono PCM16 WAV를 실시간 속도로 전송하는 API 사용 예제."""
import argparse
import asyncio
import json
import os
import wave

from websockets.asyncio.client import connect


async def stream(url, path):
    token = os.environ.get("SPEECH_API_TOKEN", "")
    if not token:
        raise ValueError("Set SPEECH_API_TOKEN in the environment")
    with wave.open(path, "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError("WAV must be mono, PCM16, 16000 Hz")
        async with connect(url, max_size=65536, compression=None) as ws:
            await ws.send(json.dumps({"type": "start", "token": token, "sample_rate": 16000, "format": "pcm_s16le"}))
            ready = json.loads(await asyncio.wait_for(ws.recv(), 15))
            if ready.get("type") != "ready":
                raise RuntimeError(f"Server rejected start: {ready.get('code', 'unknown')}")

            async def upload():
                loop = asyncio.get_running_loop()
                sent_samples = 0
                began = loop.time()
                while pcm := audio.readframes(320):
                    await asyncio.sleep(max(0, began + sent_samples / 16000 - loop.time()))
                    await ws.send(pcm)
                    sent_samples += len(pcm) // 2
                await ws.send(json.dumps({"type": "stop"}))

            async def receive():
                async for raw in ws:
                    event = json.loads(raw)
                    if event.get("type") == "error":
                        raise RuntimeError(f"Server error: {event.get('code', 'unknown')}")
                    print(json.dumps(event, ensure_ascii=False), flush=True)
                    if event.get("type") == "stopped":
                        return
                raise RuntimeError("Connection closed before stopped; results may be incomplete")

            tasks = [asyncio.create_task(upload()), asyncio.create_task(receive())]
            try:
                await asyncio.wait_for(asyncio.gather(*tasks), audio.getnframes() / 16000 + 120)
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="WebSocket endpoint ending in /v1/translate")
    parser.add_argument("--wav", required=True, help="16kHz mono PCM16 WAV file")
    args = parser.parse_args()
    asyncio.run(stream(args.url, args.wav))
