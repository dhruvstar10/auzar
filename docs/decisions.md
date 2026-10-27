# Decisions & owner guidance log

Diagnosis review (2026-10-18): missing Wi-Fi entitlements are strongly supported as a blocker
for the current CameraAccess streaming path, not yet proven to be the only failure. Verified
the local removal and found Meta maintainer confirmation of the Wi-Fi link timeout in
https://github.com/facebook/meta-wearables-dat-ios/discussions/255 . Restore proper signing
and verify network join plus actual frames before declaring the problem solved.

Newest at the bottom. Format: `YYYY-MM-DD — decision — why`.

- 2026-10-18 — Meta's built-in Live AI is not sufficient — owner tested it: it effectively
  snapshots on request rather than understanding the live feed, no step tracking.
- 2026-10-18 — Build a custom iOS app on the Meta Wearables Device Access Toolkit (DAT) —
  only way to get continuous camera frames + mic into our own AI pipeline.
- 2026-10-18 — Platform: iPhone / Swift.
- 2026-10-18 — AI provider: lean Azure OpenAI realtime (uses $150/mo Azure credits), OpenAI API
  credits as fallback. ChatGPT Plus / Google One don't include API access.
- 2026-10-18 — Owner: open-weight / open-source models on Azure are welcome, not OpenAI-only.
  Long-term goal: evaluate an on-device SLM. → Keep AI behind a swappable `AIBackend` protocol.
- 2026-10-18 — Owner: store all guidance and recurring thoughts in the project directory
  (multiple AIs, multiple sessions). `AGENTS.md` is canonical; `CLAUDE.md` imports it.
- 2026-10-18 — May publish (blog + public GitHub repo) later → no secrets in tracked files.
- 2026-10-18 — First task: Meta Wearables setup (glasses + Developer Mode + SDK access) before
  Azure setup. Start in Developer Mode (no Meta App ID needed for personal testing).
- 2026-10-18 — Owner has Ray-Ban Meta **Gen 2** → audio-only guidance (no in-lens display).
- 2026-10-18 — Tooling: Xcode must be installed (SDK, signing, deploy to iPhone, debugging).
  Editing can happen anywhere (VS Code / AI agents in terminal). Agents should build via
  `xcodebuild` from the CLI where possible; owner uses Xcode for signing setup and on-device runs.
- 2026-10-18 — Owner reiterated that progress should be tracked in this directory.
  Added `docs/status.md` for current stage, verified versus untested capabilities,
  setup discrepancies, and the next milestone; maintain it across work sessions.
- 2026-10-18 — Owner: track scenarios in `docs/scenarios.md`. S1 = DIY service on own car;
  S2 = technician service with voice-triggered photo capture into a work order. → AI layer must
  support tool calling (capture_photo, add_note, …); our app needs its own wake phrase
  (not "Hey Meta").
- 2026-10-18 — Owner: captured photos are NOT auto-attached to the work order. They are
  stored with WO-linking metadata in a staging area; the technician or service manager reviews
  them after the job and decides what to keep. AI may pre-flag junk and suggest captions.
- 2026-10-18 — Owner: photo review happens in BOTH the iPhone app (tech, right after the job)
  and a web dashboard (service manager). → Needs a shared backend (Azure) for work orders,
  photos and review state, synced from the phone. Not needed for the S1 MVP.
- 2026-10-18 — Owner: photo review can happen at either time/place (app or web). BUT the S2
  notes are high-level thoughts only. **Current goal: guide an individual fixing their own
  stuff at home** (not servicing as a business). S2 / business features come later.
- 2026-10-18 — Camera streaming from the glasses on iOS requires the Hotspot Configuration
  entitlement (Wi-Fi Direct link), which a free Apple account can't sign → owner needs the
  paid Apple Developer Program ($99/yr). Also removes the 7-day app expiry and enables TestFlight.
- 2026-10-20 — Glasses → iPhone streaming milestone reached (720p/24fps, works with phone
  locked). Glasses-side feasibility is proven; next focus is the AI loop (Azure + our own app).
- 2026-10-20 — Owner: move everything out of Google Drive into **`~/code/sbsi`** (git repo,
  future public GitHub repo). Drive folder keeps only a pointer README.
- 2026-10-22 — Azure: Foundry resource `<resource>` (rg `rg-sbsi`, **Central US**, project
  `proj-sbsi`). West US 2 rejected: no realtime models there. Owner deploys **only
  `gpt-realtime-2.1-mini` (deployment `realtime-mini`)** for now. A full `gpt-realtime-2.1`
  deployment (`realtime-full`) is deferred until we need a quality comparison. Keep the model/deployment
  name configurable in the app.
- 2026-10-22 — First guided task will be something **at the owner's desk** (faster build/test
  loop) rather than the car oil check. Exact task TBD.
- 2026-10-22 — Code hosted in a **private GitHub repo** until the owner decides to publish.
- 2026-10-22 — Owner: **no task selection.** v0 is open-ended: glasses on → open app → Start →
  talk. The model infers the task from speech + camera and tracks steps in the conversation.
  Procedure files become optional grounding later (auto-loaded when a known task is named), not
  a required step.
- 2026-10-24 — Owner: the AI must be able to **control glasses inputs/outputs itself**, starting with
  taking its own sharp photos for diagnosis. Implemented as realtime **function tools** (`ios/SBSI/
  Sources/Tools.swift`); the model decides when to call them. First tool: `take_photo`. More glasses
  I/O will be added the same way (list in `ideas.md`).

## 2026-10-26 — 12 MP photos by default for take_photo

The quick in-stream photo (1080x1440) cannot resolve small print even up close. The detail test showed a 12 MP `camera.photo` at arm's length read every label line, in ~19 s with the video off. The owner had said 35 s was too long. 12 MP is now the default, with `detail: "quick"` for scene-level looks and as the fallback. Revisit if transfer speed drops back to the ~23 KB/s seen in early runs.

## 2026-10-26 — High-detail vision model for photos

The owner asked for "a more robust model for better capture understanding". gpt-realtime-mini shrinks images to ~512 px, so
photos now also go to a chat-completions deployment named `vision` (currently `gpt-5.4-mini`, the newest GA mini on the resource).
Its reading is passed to the realtime model as text. The deployment name is generic so the model can be swapped. Desk test on two
12 MP photos: both labels read fully, and it corrected OCR errors, in 4–5 s at ~2k input tokens per photo.

## 2026-10-26 — Tiered photos: quick by default, 12 MP on request

Supersedes "12 MP photos by default" (same day). The owner wants the guide to use video frames or a quick photo when enough, and to
ask the user before a higher-res photo. Default `take_photo` = quick (read by the vision model); 12 MP only after the user agrees or
asks. Reason: 12 MP takes 17–72 s with the video paused. The large (1920x1080) size was ruled out: it gave confident misreads.

## 2026-10-26 — Product name: Auzar.ai

The owner named the app **Auzar.ai**, after the Hindi word for tools (a nod to *Home Improvement*'s Tool Time).
The GitHub repo is now `dhruvstar10/auzar` (GitHub redirects the old `sbsi` URL). Internal names (`SBSI` target, bundle ID
`com.dhruvgoel.sbsi`, Azure `<resource>` / `rg-sbsi`, folder `~/code/sbsi`) are unchanged to avoid re-provisioning.
