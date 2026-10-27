# AGENTS.md — Shared context for any AI working on this project

This is the canonical, tool-agnostic instruction file. Claude Code, Codex, Copilot, Cursor, etc.
should all read this first. `CLAUDE.md` simply imports this file. Keep project knowledge HERE
(or in `docs/`), not in any one tool's private memory.

## What we're building

**Name: Auzar.ai** (from the Hindi word for tools; renamed from the working name SBSI on 2026-10-26).
Code, bundle ID, Azure resources and the local folder `~/code/sbsi` still use "sbsi"; that's fine.

A **live, step-by-step "see what I see" assistant** for Meta Ray-Ban glasses. The user speaks;
the AI watches the glasses' camera feed and talks them through a physical task (assembling or
servicing equipment), e.g.:

1. "Press the hood release lever, left of the steering wheel."
2. "Go outside, lift the hood slightly with your left hand, feel for the latch with your right."

Unlike Meta's built-in Live AI (which in practice only reacts to snapshots when asked), this
assistant must: stream frames continuously, track which procedure step the user is on, verify
each step visually, and **speak up proactively** when a step is done or something is wrong.

## Owner instructions (standing — follow in every session)

- **Store all project guidance, decisions, and recurring thoughts in this project directory**
  (this file + `docs/`). Multiple AIs across multiple sessions iterate on this project; nothing
  important should live only in one assistant's memory or chat history.
- Track every scenario/use case the owner describes in `docs/scenarios.md`.
- When the owner gives new guidance or a decision is made, append it to `docs/decisions.md`
  (dated) and update this file if it changes standing rules.
- Use the project directory (this folder) for all project files. Since 2026-10-20 it lives at
  **`~/code/sbsi`** (git repo, public on GitHub as `dhruvstar10/auzar`). The old Google Drive folder
  (`My Drive/Projects/Meta RayBan SBSI`) only holds a pointer. Don't write project files there.
- Work may later be **published (blog) and pushed to a public GitHub repo**. So:
  - Never commit secrets (API keys, Meta App IDs/client tokens, Apple Team IDs) — use
    `.xcconfig`/env files that are gitignored.
  - Don't commit personal details either: the owner's name, emails, device IDs, or the Azure resource
    name/endpoint host (write `<resource>`; the real one is in `.env`). Licensed Apache-2.0 (`LICENSE`).
  - Keep notes reasonably clean; log interesting findings in `docs/blog-notes.md`.
- Don't lock in to a single AI vendor. Keep the AI layer behind an abstraction so OpenAI,
  Azure-hosted open-weight models, and eventually an **on-device SLM** can be swapped in.

## Current focus

**S1: help an individual fix or maintain their own stuff** (home, appliances, car, furniture).
Business/technician use (work orders, photo review, manager dashboard) is captured in
`docs/scenarios.md` as **high-level, later** thoughts. Don't build it yet; just don't paint
the design into a corner.

## Owner's environment & resources

- Phone: **iPhone** → native **Swift** app. Mac with **Xcode 26.6**. If `xcode-select` still
  points at CommandLineTools, run Xcode CLI tools with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …`.
- Glasses: **Ray-Ban Meta Gen 2** (no display — guidance is audio-only).
- AI budget: **$150/month Azure credits** (preferred), some **OpenAI API credits**.
  ChatGPT Plus and Google One do NOT include API access — don't plan around them.
- Leaning: **Azure OpenAI `gpt-realtime` / `gpt-realtime-mini`** for the first MVP; open-weight
  models on Azure AI Foundry are welcome too; on-device SLM is a long-term goal.

## Architecture (current plan)

```
Glasses (camera + mic) ──BT/Wi-Fi──► iOS app (Meta DAT SDK: MWDATCore, MWDATCamera)
                                        │ frames @ ~1–2 fps (low/medium res) + mic audio
                                        ▼
                               AIBackend protocol (swappable)
                     ├─ Azure OpenAI realtime (MVP)
                     ├─ OpenAI realtime (same code, different endpoint)
                     ├─ Azure open-weight VLM + STT/TTS chain
                     └─ On-device SLM/VLM (future)
                                        │ + procedure file (steps, visual checks, warnings)
                                        ▼
Glasses speakers ◄── Bluetooth audio ── spoken guidance
```

Key design points:
- **Verified glasses facts (2026-10-20, Gen 2, SDK 1.0.1)**, details in `docs/setup/01-meta-wearables-setup.md`:
  - Live stream works at 720×1280 @ 24 fps. It's soft from compression, so use high-quality still
    photo capture when fine detail matters.
  - **Streaming keeps running with the phone locked** IF Info.plist has the `external-accessory`
    background mode + `UISupportedExternalAccessoryProtocols: [com.meta.ar.wearable]` and the app
    does NOT end the session on `didEnterBackground` (Meta's sample does both the wrong way).
  - Requires the **paid Apple Developer team** (Hotspot entitlement for the Wi-Fi Direct video link).
  - iOS asks to join the glasses' Wi-Fi on each new stream, so start one stream per task and keep it alive.
  - Handle `datAppOnTheGlassesUpdateRequired` → `openDATGlassesAppUpdate()`.
  - Full-quality stills (4032×3024) need `camera.photo` (experimental), NOT `stream.capturePhoto` (1080×1440 only).
    `camera.photo` speed varies: ~20–25 KB/s in early runs (12 MP ≈ 60 s, large 1920x1080 ≈ 18 s, video off; 2026-10-26).
    Later run: 12 MP in ~19 s (~75 KB/s), and only 12 MP made small print readable, so it IS the default for `take_photo` now
    (the quick photo is the fallback). full/medium and full/low failed with captureFailure. Photos come back as HEIC.
    Stop the stream, start Photo, capture, stop Photo, then restart the stream (restarting while Photo runs kills video).
  - **One camera, at the left front corner** of the frame. Up close, a label held in front of the nose drifts right and out of
    frame; ask the user to hold it in front of their LEFT eye.
  - Touching the side touchpad can PAUSE the camera session, even a volume slide (2026-10-24, likely),
    and it may not resume by itself. The app does a full stop→start after 5 s paused. Change volume with the phone buttons.
- gpt-realtime-mini **downsizes every image to ~512 px** (≤323 tokens; `detail:"high"` is ignored), so send
  **crops** for fine detail (tested 2026-10-26: a 2× crop read 15 px text, the full photo didn't).
- Realtime APIs don't ingest video; the app sends **still frames** as images. Keep only the
  last few frames in context to control cost.
- **Proactivity is app-driven**: periodically (or on scene change) trigger a silent
  "is step N done? if yes give step N+1, else stay silent" check.
- The app owns **procedure state** (current step) and injects it into the model instructions.
- Never ship API keys in the app — a small Azure Function issues short-lived tokens.

## Repo layout

- `AGENTS.md` — this file (canonical context). `CLAUDE.md` imports it.
- `docs/scenarios.md` — **use cases we're building for** (DIY car service, technician service +
  work order photos, …). Keep it updated; new scenarios go here.
- `docs/status.md` — **current stage, latest verified results, next milestone.** Update after
  meaningful work.
- `docs/decisions.md` — dated log of decisions and owner guidance.
- `docs/status.md` — current progress, evidence, unresolved checks, and next actions;
  read at session start and update after meaningful project work.
- `docs/ideas.md` — open questions / future directions (open-weight, on-device SLM, …).
- `docs/setup/` — step-by-step setup guides (Meta wearables, Azure, Xcode).
- `README.md` — public front page (purpose, scenarios, architecture diagram, how to swap models/add tools). Linked from the owner's website; keep it current when the architecture or setup changes.
- `docs/blog-notes.md` — findings worth writing up publicly.
- `ios/` — **Auzar iOS app (v0; home-screen name "Auzar").** App icon (A-wrench with an eye, made by Codex): `ios/SBSI/Assets.xcassets/AppIcon.appiconset` (one 1024 px PNG). Xcode project is GENERATED by XcodeGen from
  `ios/project.yml` (`cd ios && xcodegen`); don't hand-edit or commit `SBSI.xcodeproj`.
  Secrets: `tools/gen_ios_secrets.sh <TEAM_ID>` writes gitignored `ios/Config/Secrets.xcconfig` from `.env`.
  Build/install from CLI:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/SBSI.xcodeproj -scheme SBSI -destination 'id=<DEVICE_ID>' -allowProvisioningUpdates build`
  then `xcrun devicectl device install app --device <DEVICE_ID> <DerivedData>/Build/Products/Debug-iphoneos/SBSI.app`.
  Note: the CLI can reuse provisioning profiles but can't create them ("No Accounts"). The first build
  of a new bundle ID must be done once from the Xcode GUI.
  Sources: `GlassesCamera` (DAT session/stream), `VideoPreview` (hardware full-rate preview), `VideoDecoder` (HEVC→images for the model), `AudioIO` (HFP mic/speaker, 24 kHz PCM16),
  `RealtimeClient` (WebSocket), `Assistant` (frames every N s, keeps last 3 images, barge-in,
  out-of-band proactive check via forced `proactive_decision` call), `Prompts` (guide instructions),
  `Tools` (function tools the model calls to control the glasses, e.g. `take_photo`), `PhotoReader` (on-device OCR + main-label crop),
  `VisionClient` (photo → `vision` deployment for high-detail reading), `Log`. Spoken photo cues are pre-recorded
  (`tools/gen_cues.py` → `ios/SBSI/Resources/cues/`); re-run it if a cue line or the voice changes. Azure CLI is set up (`az`, resource group `rg-sbsi`).
  **Pull logs from the phone** (runs away from the Mac; the app appends to `Documents/logs/<yyyy-mm-dd>.log`,
  also visible in the Files app → On My iPhone → Auzar):
  `xcrun devicectl device copy from --device <DEVICE_ID> --domain-type appDataContainer --domain-identifier com.dhruvgoel.sbsi --source Documents/logs --destination tools/out/phone-logs`.
  Session images (glasses photo originals, the exact images sent to the model, frames): same command with
  `--source Documents/sessions --destination tools/out/sessions`.
  Live logs instead: `xcrun devicectl device process launch --console --terminate-existing --device <DEVICE_ID> com.dhruvgoel.sbsi`
  (the phone must be unlocked and connected).
- `backend/` — (to come) Azure Function for token minting. (Later, for S2: work-order/photo sync.)
- `procedures/` — (to come) task procedure files (JSON/Markdown).

## Reference links

- **This repo (PUBLIC since 2026-10-26; everything pushed is visible to anyone):** https://github.com/dhruvstar10/auzar. Commit
  identity is the GitHub noreply address (repo-local git config). Don't commit personal emails.

- Meta Wearables DAT docs: https://wearables.developer.meta.com/docs/develop/dat/build-overview/
- iOS integration: https://wearables.developer.meta.com/docs/develop/dat/build-integration-ios/
- iOS SDK (SPM): https://github.com/facebook/meta-wearables-dat-ios. Local checkout with our
  patched CameraAccess sample: `~/code/meta-wearables-dat-ios` (uncommitted local changes).
- Version dependencies: https://wearables.developer.meta.com/docs/develop/dat/version-dependencies/
- Meta Wearables MCP server (for AI coding tools): https://mcp.developer.meta.com/wearables
