# Ideas & open questions

## Model options beyond OpenAI (owner wants these explored)

No open-weight model offers a hosted realtime speech-to-speech endpoint on Azure (as of
2026-10), so open-weight paths are a **chain**: speech-to-text → vision-language model → text-to-speech.

Candidates on Azure AI Foundry (verify availability/pricing in the catalog before use):
- **Phi-4-multimodal** (Microsoft, open weights) — text + image + audio input; small; also a
  bridge to on-device since the same weights can run locally.
- **Llama 4 (Scout / Maverick)** — strong open-weight vision models.
- **Mistral** vision models, **Qwen-VL** family if listed.
- STT/TTS: Azure AI Speech (low latency, streaming), or Whisper.

Trade-off: chained pipelines add latency (~1–3 s+) vs realtime APIs, but give model freedom and
cheaper per-minute cost. A good hybrid: realtime model for conversation; a separate VLM called
for careful step verification ("is this the right bolt?").

## On-device SLM (long-term goal)

Why: zero API cost, offline use (garages, basements), privacy, lower latency for simple checks.

Candidates to evaluate on iPhone (via MLX Swift / Core ML / llama.cpp):
- **Gemma 3n** — designed for on-device; image + audio input.
- **Apple FastVLM** — Apple's efficient on-device VLM (MLX).
- **SmolVLM2**, **Qwen2.5-VL-3B**, **Phi-4-multimodal** (quantized).
- Apple **Foundation Models** framework (on-device ~3B) — check whether image input is exposed
  to third-party apps in current iOS.
- On-device STT/TTS: Apple Speech framework / `AVSpeechSynthesizer` (already on device).

Likely realistic split: on-device model for cheap continuous checks ("did the scene change?",
"is the hood open?") and to gate cloud calls; cloud model for reasoning-heavy steps.
Concerns: iPhone thermals + battery while also streaming from glasses; model quality on
fine-grained mechanical details.

## Glasses I/O as tools (owner direction, 2026-10-24)

The model should drive the glasses itself, through realtime function tools (`Tools.swift`), rather
than the user doing it by hand. Done: `take_photo` (full-res still). Candidates, checked against
what DAT SDK 1.0.1 exposes:
- `take_photo` with zoom/crop: ask the user to move closer, or crop the full-res still to a region.
- `record_clip`: short video for a motion or noise diagnosis, e.g. "what is this rattle?" (the SDK has stream audio frames).
- Change stream quality: raise the frame rate or resolution while the user does a fiddly step, and lower it when idle to save battery and tokens.
- `save_photo` with a label: keep evidence ("before"/"after", or S2 work-order photos) on the phone.
- Pause or resume watching (privacy), and react to the touchpad tap that pauses the session.
- Look things up: manuals, part diagrams, torque specs (a web/doc search tool) for grounding.
- Not exposed by the SDK as far as we know: the glasses LED, the display (Gen 2 has none) and the camera's exposure or focus. Recheck with each SDK release.

## Open questions

- Glasses are Gen 2 (no display), so output is voice-only. A Display model could show text in-lens later.
- Procedure source: hand-written procedure files vs. generating them from manuals (RAG)?
- ~~Git repo location~~ → resolved 2026-10-20: project moved to `~/code/sbsi` (outside Drive).

## SDK 1.0 features that matter to us (from CHANGELOG, 2026-09-24)

- **[Experimental] Voice invocations:** "Hey Meta, launch <our app>" via `VoiceInvocationsStream`
  (`LaunchApp`). Could solve the wake-phrase problem for starting a session.
- **[Experimental] Inputs:** glasses button/touchpad events (`CapturePressType`, etc.). The
  capture button could trigger "take photo" / "next step" without speaking.
- **[Experimental] Speech:** on-device transcription from glasses mic (`MWDATSpeech`). Free STT
  for open-weight/on-device pipelines.
- **[Experimental] Photo capture:** `Camera.photo` high-quality stills with resolution/quality controls.
- **[Experimental] Camera audio streaming:** `audioFramePublisher` alongside video.
- **Device state:** battery, thermal level, don state (on/off head). Use to warn the user and throttle frame rate.
- Experimental features can be built/tested but apps using them can't be published yet. Fine for us now.
- ⚠️ Sample app ends the session when the iPhone app is backgrounded. Need to verify whether
  streaming can continue with the phone locked/in a pocket. This is critical for hands-free use.
