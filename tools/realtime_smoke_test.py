"""Smoke test for the Azure realtime deployment.

Sends one image + a text question over the realtime WebSocket and saves the spoken reply
as a WAV file, so we can check: connection/auth, image input, and audio output.

Usage:
    .venv/bin/python tools/realtime_smoke_test.py [image.png|jpg] [out.wav]

Reads AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_API_KEY, AZURE_OPENAI_REALTIME_DEPLOYMENT from .env.
Never prints the key.
"""

import asyncio
import base64
import json
import mimetypes
import pathlib
import sys
import time
import wave

import websockets

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_env() -> dict:
    env = {}
    for line in (ROOT / ".env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


async def main() -> None:
    env = load_env()
    image_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
    out_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "tools" / "out" / "reply.wav"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    host = env["AZURE_OPENAI_ENDPOINT"].replace("https://", "wss://").rstrip("/")
    url = f"{host}/openai/v1/realtime?model={env['AZURE_OPENAI_REALTIME_DEPLOYMENT']}"
    headers = {"api-key": env["AZURE_OPENAI_API_KEY"]}

    t0 = time.monotonic()
    async with websockets.connect(url, extra_headers=headers, max_size=None) as ws:
        print(f"connected in {time.monotonic() - t0:.2f}s")

        await ws.send(json.dumps({
            "type": "session.update",
            "session": {
                "type": "realtime",
                "instructions": (
                    "You are a hands-on repair guide speaking through smart glasses. "
                    "Be brief: one or two short sentences."
                ),
                "output_modalities": ["audio"],
                "audio": {"output": {"voice": "alloy", "format": {"type": "audio/pcm", "rate": 24000}}},
            },
        }))

        content = [{"type": "input_text", "text": "What do you see? Answer in one sentence."}]
        if image_path:
            mime = mimetypes.guess_type(image_path.name)[0] or "image/png"
            b64 = base64.b64encode(image_path.read_bytes()).decode()
            content.insert(0, {"type": "input_image", "image_url": f"data:{mime};base64,{b64}"})
            print(f"sending image {image_path.name} ({image_path.stat().st_size // 1024} KB)")
        else:
            content = [{"type": "input_text", "text": "Say hello and tell me you're ready to help fix things."}]

        await ws.send(json.dumps({
            "type": "conversation.item.create",
            "item": {"type": "message", "role": "user", "content": content},
        }))
        t_req = time.monotonic()
        await ws.send(json.dumps({"type": "response.create"}))

        audio = bytearray()
        transcript = []
        first_audio = None
        async for raw in ws:
            ev = json.loads(raw)
            kind = ev.get("type", "")
            if kind == "error":
                print("ERROR:", json.dumps(ev.get("error"), indent=2))
                return
            if kind == "response.output_audio.delta":
                if first_audio is None:
                    first_audio = time.monotonic() - t_req
                audio += base64.b64decode(ev["delta"])
            elif kind == "response.output_audio_transcript.delta":
                transcript.append(ev["delta"])
            elif kind == "response.done":
                usage = ev.get("response", {}).get("usage")
                if usage:
                    print("usage:", json.dumps(usage))
                break

    with wave.open(str(out_path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(24000)
        w.writeframes(bytes(audio))

    print(f"time to first audio: {first_audio:.2f}s" if first_audio else "no audio received")
    print(f"reply audio: {len(audio) / 48000:.1f}s -> {out_path}")
    print("transcript:", "".join(transcript))


if __name__ == "__main__":
    asyncio.run(main())
