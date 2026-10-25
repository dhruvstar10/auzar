# Project status

Last updated: 2026-10-24

**2026-10-24 update: full loop works end to end (v0 app `ios/`, "SBSI Guide").** First desk test
(~3 min, log `tools/out/run1.log`, gitignored): glasses mic over Bluetooth HFP → `realtime-mini` →
speech back through the glasses, with frames every 2 s. Owner verdict: "This was great." Observed:
- Replies ~2–4 s after the user stops talking. Scene answers were correct (desk, monitor, phone stand,
  blue bag colour, MacBook Pro). No echo or self-interruption problems reported (mic muted while the guide talks).
- **Limitation: it can't read small text** from the 720p stream ("too small and a bit blurred").
  It told the user it "can't take a snapshot on my own". → Added a `take_photo` function tool
  (full-res still via `stream.capturePhoto(.jpeg)`, sent at ≤2048 px). It is untested on device yet.
- Cost of the run: 81 frames, 13.3k input tokens (8.4k image), 3.4k output tokens.
- One transient `videoStreamingError`; the stream kept going. The first proactive check returned
  non-JSON text; later ones returned `{"speak": false}` correctly. Proactive speak-up not yet seen firing.
- **`take_photo` verified (run 2, `tools/out/run2.log`).** The model took a photo when asked and again on
  its own to read a label. It read "Expo White Board Care … 10 oz / 297 ml", which the video
  frames couldn't do. Capture takes ~2.7–3.2 s, 320–375 KB per photo. Issues: it once took a redundant second
  photo straight after the first, and proactive checks often return empty or malformed text.
  **Fixed (untested on device):** repeat `take_photo` calls within 8 s (or while a photo is in flight)
  reuse the fresh photo, and the proactive check now forces a `proactive_decision` function call.
  A desk test against Azure gave valid structured output, but the model leans towards speak=true,
  so watch for over-talking.
- Next (was: test `take_photo`) (reading text, a label or model plate). Then a real multi-step task
  (proactive step confirmation). Then more glasses I/O as tools (see `ideas.md`).

**2026-10-22 update: Azure AI side verified.** Foundry resource `sbsi-foundry-dg` (Central US),
deployment `realtime-mini` = `gpt-realtime-2.1-mini`. `tools/realtime_smoke_test.py` sent an image
+ question and got a correct spoken answer (first audio in ~2.1 s, ~323 tokens per image). Key lives
only in gitignored `.env`. **Both halves now work separately** (glasses→phone video; image→spoken
answer). **Next: our own iOS app joining them**, i.e. glasses frames + glasses mic → realtime model
→ speech out through the glasses, running one guided task. Details: `setup/02-azure-setup.md`.

## Goal and confirmed context

- Build a spoken, step-by-step equipment assistant using the glasses' camera view.
- Owner has Ray-Ban Meta Gen 2 glasses and an iPhone.
- Owner reports built-in Live AI requires snapshots to analyze and reply and does not meet
  the desired continuous-guidance experience. This is an observation of their experience,
  not a verified statement about Meta's internal implementation.
- Keep project context and progress in this directory for continuity across assistants.
- Existing provider preferences and architecture are recorded in `../AGENTS.md` and
  `decisions.md`; they remain plans pending implementation and testing.

## Current stage

**2026-10-20 update: glasses → iPhone streaming verified.** Paid Apple Developer team active;
Hotspot + wifi-info entitlements restored and verified in the signed app (`codesign`). Preview works:
measured **720×1280 @ ~24 fps** (`.high`, hvc1). The image looks soft (compression), so plan on still
photos for fine detail. **Streaming continues with the phone locked** (~18 s test, frames kept
flowing) after (a) removing the sample's end-session-on-background and (b) adding the
`external-accessory` background mode + `UISupportedExternalAccessoryProtocols:
[com.meta.ar.wearable]`. iOS prompts to join the glasses' Wi-Fi on each new stream. Evidence:
`[SBSI]` logs captured via `devicectl --console`; details in `setup/01-meta-wearables-setup.md`.
Project moved to `~/code/sbsi` (git). Still not done: audio round-trip, AI integration, battery
drain, longer locked-phone runs.

Earlier records (2026-10-18):

Latest setup records (read from the project notes; not re-tested during this status review):
- Xcode 26.6 and iOS SDK 26.5/simulator are installed; Apple ID is signed in.
- iPhone: iOS 27.0.1. Meta AI app: 294.1.0.28.163. Glasses firmware: V129.
- Meta SDK 1.0.1 checkout is recorded at `~/code/meta-wearables-dat-ios`, commit bbae597.
  Start with `samples/CameraAccess/CameraAccess.xcodeproj` there.
- CameraAccess built for simulator and was signed/installed on the iPhone with a free
  Personal Team after removing Wi-Fi Information and Hotspot capabilities. The device
  build worked with Xcode 26.6 despite the newer phone OS.
- A missing DAT component on the glasses was encountered. The local sample was patched
  to expose the existing update API; Meta AI → Settings → App Info provides its Install flow.
- Session start now works, but Preview fails with "Device is not connected". The setup
  log attributes this to the removed Hotspot entitlement and records paid Apple Developer
  enrollment plus restoring both capabilities as the next fix. Streaming after that fix
  has not yet been verified. See setup guide section F for the investigation.
- Current scope is personal DIY repair/maintenance (S1). Technician work orders and
  photo review (S2) are later ideas, documented in `scenarios.md`.

Hardware integration and sample debugging. This directory currently contains documentation;
the modified sample is in the external SDK checkout. There is no custom `ios/` app or
`backend/` implementation yet. Successful camera streaming, audio round-trip, AI integration,
latency, and procedure verification are not recorded. These are project log findings,
not hardware checks repeated during this status review.

## Next milestone

~~Run CameraAccess and see live frames~~ ✅ done 2026-10-20 (steps 1–4 below completed).

Now: **AI loop.** (a) Azure OpenAI resource + `gpt-realtime-mini` deployment (`setup/02-azure-setup.md`).
(b) Our own iOS app in `ios/`, carrying over the verified glasses settings (see AGENTS.md).

1. ✅ Paid Apple Developer team.
2. ✅ Capabilities restored, DAT-update UI patch kept.
3. ✅ Rebuilt/reinstalled.
4. ✅ Live frames verified.
5. Test simultaneous microphone input and spoken playback through glasses, including
   interruption and phone-lock/background behavior, before adding the AI loop.
6. Add automatic frame selection, voice interaction, and one manual-grounded procedure.

## Evidence and details to recheck

- 2026-10-18 diagnosis review: inspected the local git diff and confirmed both HotspotConfiguration
  and wifi-info entitlements were removed. Meta maintainer alexsinkmeta confirms in discussion
  #255 that this streaming failure can be a timeout establishing the glasses' higher-bandwidth
  Wi-Fi link while Bluetooth remains connected. This strongly supports the entitlement diagnosis
  for this sample, but no local runtime log or successful restored-entitlement test proves it is
  the sole fault. Binary imports alone were insufficient proof. Local SDK guidance still mentions
  Bluetooth Classic streaming and should not be used to assert the current transport universally.
  After restoring proper signing, verify the shipped entitlements, the system Wi-Fi join prompt,
  Local Network permission, and frame delivery. Source:
  https://github.com/facebook/meta-wearables-dat-ios/discussions/255
- Meta's official CameraAccess README says Developer Mode needs no Meta credentials;
  other release channels require `META_APP_ID` and `CLIENT_TOKEN`.
- The README inspected on 2026-10-18 lists iOS 17.2+, Xcode 26.4+, and Swift 6.3+.
  The setup guide now distinguishes its listed SDK minimum from the sample minimum;
  the recorded iPhone version exceeds both. Verify against the pinned release when building.
- ~~Locked-phone streaming unverified~~ → verified for ~18 s on 2026-10-20 (see above). Longer
  runs and pocket use with audio still to test.
- Public distribution requirements remain to be verified. Do not treat the existing
  setup note's ExternalAccessory explanation as a confirmed blanket App Store prohibition.
- Automatic frame sampling and proactive step checking are proposed app behavior.
  Reliable visual verification of every step is not established; hidden actions may
  require user confirmation or another view.

References:
- https://github.com/facebook/meta-wearables-dat-ios/blob/main/samples/CameraAccess/README.md
- https://github.com/facebook/meta-wearables-dat-ios
- https://developers.meta.com/wearables/faq/

## Update practice

Update this file after meaningful project work with completed checks, findings, blockers,
and the next action. Append decisions to `decisions.md`; keep setup checklists accurate.
This is a session-maintained record, not a background filesystem monitor.
