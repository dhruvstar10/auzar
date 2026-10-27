#!/usr/bin/env python3
"""Desk test for the photo-understanding model (the `vision` deployment).

Sends saved glasses photos (and optional OCR text) to the Azure chat-completions deployment named by
AZURE_OPENAI_VISION_DEPLOYMENT in .env (default "vision") and prints its answer, latency and tokens.
Same request shape as the app's VisionClient.swift, so results carry over.

  tools/vision_test.py PHOTO [CROP] [--ocr FILE] [--question "..."] [--detail high|low|auto]

HEIC photos are converted with `sips`. Stdlib only; never prints the API key.
"""
import argparse
import base64
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SYSTEM = (
    "You analyse a photo from the user's smart-glasses camera for a hands-on repair guide. "
    "Answer the question about the object the user is holding or looking at. Read all text on it "
    "exactly, including small print, numbers, part or model numbers and barcodes' human-readable "
    "digits. If on-device OCR text is given, use it to confirm your reading but correct obvious OCR "
    "errors from what you see. Ignore text on screens or papers in the background unless asked. "
    "Say plainly what you can't read; never guess brand names or codes you can't actually make out "
    "(on a low-resolution photo this produced confident wrong readings). Be factual and compact: short "
    "lines, no preamble."
)


def env():
    values = {}
    for line in (ROOT / ".env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            values[k.strip()] = v.strip()
    return values


def jpeg_bytes(path: Path, max_side: int) -> bytes:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "img.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "85", "-Z", str(max_side),
                        str(path), "--out", str(out)], check=True, capture_output=True)
        return out.read_bytes()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("photo", type=Path)
    ap.add_argument("crop", type=Path, nargs="?")
    ap.add_argument("--ocr", type=Path)
    ap.add_argument("--question", default="Read the label on what I'm holding.")
    ap.add_argument("--detail", default="original")
    ap.add_argument("--max-side", type=int, default=4032)
    ap.add_argument("--effort", default="low", help="reasoning_effort; 'none' to omit")
    args = ap.parse_args()

    e = env()
    endpoint = e["AZURE_OPENAI_ENDPOINT"].rstrip("/")
    deployment = e.get("AZURE_OPENAI_VISION_DEPLOYMENT", "vision")
    content = [{"type": "text", "text": f"Question: {args.question}"}]
    if args.ocr:
        content.append({"type": "text", "text": "On-device OCR of the full photo:\n" + args.ocr.read_text()})
    for label, path in (("Whole photo:", args.photo), ("Close-up of the main label:", args.crop)):
        if path:
            data = base64.b64encode(jpeg_bytes(path, args.max_side)).decode()
            content.append({"type": "text", "text": label})
            content.append({"type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{data}", "detail": args.detail}})
    body = {"model": deployment, "max_completion_tokens": 2000,
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": content}]}
    if args.effort != "none":
        body["reasoning_effort"] = args.effort

    req = urllib.request.Request(f"{endpoint}/openai/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"api-key": e["AZURE_OPENAI_API_KEY"], "Content-Type": "application/json"})
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as err:
        print(f"HTTP {err.code}: {err.read().decode()[:800]}")
        return
    print(f"--- {deployment} ({resp.get('model')}), {time.time() - start:.1f} s, usage {resp.get('usage')}")
    print(resp["choices"][0]["message"]["content"])


if __name__ == "__main__":
    main()
