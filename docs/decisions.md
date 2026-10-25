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
- 2026-10-22 — Azure: Foundry resource `sbsi-foundry-dg` (rg `rg-sbsi`, **Central US**, project
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
