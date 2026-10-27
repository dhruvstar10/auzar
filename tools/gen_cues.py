#!/usr/bin/env python3
"""Pre-record the app's spoken photo cues in the guide's voice, bundled with the app.

Live out-of-band cue responses doubled the line once and add latency (2026-10-27), so the cues are
generated here with the realtime deployment and the same voice as Assistant.swift, checked word for
word against the transcript, and saved as raw PCM16 mono 24 kHz in ios/SBSI/Resources/cues/<key>.pcm.
Re-run after changing a line or the voice:  .venv/bin/python tools/gen_cues.py
"""
import asyncio
import base64
import json
import re
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios/SBSI/Resources/cues"
VOICE = "alloy"  # keep in sync with Assistant.swift session.update

# Keep in sync with Cue in AudioIO.swift.
CUES = {
    "quick_start": "Taking a photo. Hold still.",
    "quick_done": "Got it.",
    "full_start": "Taking a high-resolution photo. Hold still for a few seconds.",
    "full_done": "Got it, you can move. I'm processing the photo; this can take up to a minute.",
    "failed": "Sorry, the photo didn't come through.",
}


def norm(text):
    return re.sub(r"[^a-z0-9 ]", "", text.lower().replace("-", " ")).split()


async def record(ws, text):
    await ws.send(json.dumps({"type": "response.create", "response": {
        "conversation": "none", "input": [], "output_modalities": ["audio"],
        "instructions": f'Say exactly this, word for word, in a calm, friendly voice, and nothing else: "{text}"'}}))
    pcm, transcript = bytearray(), ""
    async for msg in ws:
        event = json.loads(msg)
        if event["type"] == "response.output_audio.delta":
            pcm += base64.b64decode(event["delta"])
        elif event["type"] == "response.output_audio_transcript.done":
            transcript = event["transcript"]
        elif event["type"] == "error":
            raise RuntimeError(event["error"])
        elif event["type"] == "response.done":
            return bytes(pcm), transcript


async def main():
    env = dict(line.split("=", 1) for line in (ROOT / ".env").read_text().splitlines()
               if "=" in line and not line.startswith("#"))
    host = env["AZURE_OPENAI_ENDPOINT"].replace("https://", "").rstrip("/")
    url = f"wss://{host}/openai/v1/realtime?model={env['AZURE_OPENAI_REALTIME_DEPLOYMENT']}"
    OUT.mkdir(parents=True, exist_ok=True)
    async with websockets.connect(url, extra_headers={"api-key": env["AZURE_OPENAI_API_KEY"]}) as ws:
        await ws.send(json.dumps({"type": "session.update", "session": {
            "type": "realtime", "audio": {"output": {"voice": VOICE, "format": {"type": "audio/pcm", "rate": 24000}}}}}))
        for key, text in CUES.items():
            for attempt in range(3):
                pcm, transcript = await record(ws, text)
                if norm(transcript) == norm(text):
                    break
                print(f"  {key}: got {transcript!r}, retrying")
            else:
                raise SystemExit(f"{key}: never matched")
            (OUT / f"{key}.pcm").write_bytes(pcm)
            print(f"{key}: {len(pcm) / 48000:.1f} s  {transcript!r}")


asyncio.run(main())
