# Project status

Last updated: 2026-10-26

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
- **Field test away from the Mac (run 3, `tools/out/phone-logs/2026-10-25.log`): failed.** Owner: "it never
  fully connected"; no usable video; guide text appeared but **no audio** after restarting the glasses.
  Causes found in the log/code: (1) no handling of audio route/config changes, so when the glasses'
  Bluetooth link dropped and came back the AVAudioEngine stayed stopped. Speech was silent, and the
  mic stayed muted forever because playback never "finished", so the user was never heard. (2) A
  double Start/Stop tap left the camera off. (3) `noEligibleDevice` (glasses asleep) still started
  the AI on the iPhone earpiece/mic without saying so. (4) Repeated `videoStreamingError`, cause unknown;
  no frame-rate log existed. Suspect: `.raw` codec at 720p over the Wi-Fi link (the Meta sample uses `.hvc1`,
  which we measured at a smooth 24 fps but which needs a VideoToolbox decoder).
  **Fixes (untested on device):** the audio engine rebuilds on route/config/interruption changes; there's a time-based
  fallback for "is speech playing"; Start/Stop debounce; Start refuses without glasses and shows a clear
  message; warning when audio isn't on the glasses; fps in the UI and logged every 10 s.
  If fps is low or errors repeat, switch to `.hvc1` + decoder.
- **Run 4 (same log, 03:07–03:09 UTC).** Audio fixes worked: audio stayed on the glasses and the user was heard.
  Owner: "Barge in wasn't working properly. Taking a picture never worked. It kept talking too much."
  - The **camera was paused by the glasses** ~17 s in (stream → paused, then session → paused) and **never
    resumed** until Stop. The owner did NOT tap: they were **sliding on the touchpad to raise the volume**. Likely
    the slide registered as a tap, which pauses (unconfirmed). Every `take_photo` then failed instantly, and the
    model blamed the user for moving. Fix: auto full restart (stop → start) after 5 s paused, plus a "Restart camera" button.
  - The raw stream **dropped from 720×1280 to 504×896** (13.6 fps), and fps was 0.2–0.5 around errors.
    That points to link bandwidth. `.hvc1` remains the candidate fix.
  - **Barge-in was blocked by design**: "mute mic while guide talks" dropped all mic audio.
  - Replies ran 3–5 sentences, with filler ("let me think…") and closing offers.
  **Fixes (untested on device):** an echo gate replaces the mute. While the guide speaks, mic audio below
  -30 dBFS (adjustable in the UI) is sent as silence, louder speech passes through to interrupt, and peak
  levels are logged every 10 s for tuning. Pause handling: an app line, a system note to the model, a spoken
  "tap to resume", and `take_photo` returns the real reason. The prompt has a hard brevity rule (≤2 short
  sentences, no filler or offers), and the proactive check defaults to quiet.
- **Run 5 (03:16–03:17 UTC).** No pause; replies were short (2 sentences), so the brevity fix worked. Echo-gate data:
  guide leakage at the mic was −52 to −60 dBFS and the user's voice −20 to −22, so the −30 gate is well placed.
  Barge-in was not exercised. **Both photos timed out (10 s)** while video fell to 0.1 fps at 504×896.
  **The owner keeps the phone in a pocket (locked) after Start.** The only successful photos (run 2) were
  with the phone unlocked on the desk. Hypotheses: photo capture doesn't work with the app in the
  background, and/or the body blocks the glasses↔phone Wi-Fi link. Changes (untested on device):
  stream at **2 fps** (was 15) to free bandwidth (per Meta's docs, the SDK holds ≥15 fps by cutting
  resolution); the photo timeout is 6 s, falling back to the newest full-res video frame; app state
  (foreground/locked) is logged on failure; no proactive check while a photo is in flight.
  To isolate the cause, test photos with the phone (a) unlocked on the counter and (b) locked in a pocket.
- **Run 6 (2026-10-25 20:35–20:40 UTC): first real task** (replacing what is probably a door ball catch at the top of
  a dummy-handle door). 5.5 min, 153 frames, 6 photos, 95.6k input / 8.2k output tokens. App in the foreground the whole time.
  - **Barge-in verified**: the guide was cut off mid-word ("I still can") by "What do you see?".
  - Photos: 3/6 succeeded at 4.6–5.8 s (150–175 KB); 3 hit the 6 s timeout, so the timeout was too tight. The fallback frame worked.
  - **The raw stream stayed at 504×896 even at 2 fps**, with 2× videoStreamingError. Conclusion: raw saturates the link.
  - The model never identified the part; it gave generic door-handle steps for unidentified hardware, and the owner
    corrected it. Proactive checks were mostly quiet, with 2 generic speak-ups.
  - "End session" by voice: the model said "session ended" but nothing stopped (it had no tool).
  **Changes (untested on device):** **switched to `.hvc1` @ 15 fps with our own VideoToolbox decoder** (`VideoDecoder.swift`;
  all frames decoded, ~5 images/s made); photo timeout 15 s and photo dimensions logged; `end_session` tool;
  prompt: don't give steps for unidentified parts, and accept the user's corrections.
- **Run 7 (2026-10-26 03:18 UTC): hvc1 verified.** The decoder came up at 720×1280 at ~15 fps (it later adapted to 504×896
  but stayed smooth). **Photos: 2/2 in 2.0–2.7 s at 1080×1440.** It still couldn't read a barcode or small text from the photo.
  **Root cause (tested via `tools`-style script against Azure):** gpt-realtime-mini downsizes every image to ~512 px
  (~323 tokens max; `"detail": "high"` is ignored, with the same 323 tokens). On a synthetic 1080×1440 label with ~15 px text, the full image
  misread the serial; **half-size (540×720) and third-size crops read it exactly.** Fix: `take_photo` now sends an
  overview plus a 2× zoom crop (`zoom` param: center/top/bottom/left/right/corners). Proactive check-ins still nag
  (2 repeats of "hold it closer").
  **New: session media saved** to `Documents/sessions/<timestamp>/{photos,frames}` (glasses originals, the exact
  images sent, every frame), viewable in the Files app.
- **Run 8 (2026-10-26 03:25 UTC).** Photos 4/4 in ~2 s (1080×1440); `end_session` worked. It still couldn't read labels.
  Inspecting the saved originals (`tools/out/sessions/2026-10-25_20-25-46/photos`): **photo quality is fine** (a human can read
  "HOMOTEX 2 Pack Drive-in Ball Catch…" and "Walgreens Ibuprofen 200 mg"). But hand-held objects sit **low-right** in the
  glasses' view, so the fixed **centre zoom missed the label**, and the small print is only ~10 px at arm's length.
  Change: **on-device Apple Vision OCR + barcode reading** on the full-res photo (`PhotoReader.swift`, en-US only). The
  text goes into the tool output as hints, and the zoom crop is placed around the detected text. A Mac test on the real photos
  read "Ibuprofen", "100 TABLETS" and **"EXP 2028/02"** (the expiry the model couldn't read), but garbled the tiny bag
  print. An upscaled second pass was not reliably better. The prompt now asks the user to hold labels a hand's length away, in front of their eyes.
  Option still open: send photos to a high-detail vision model (gpt-4.1/gpt-5-mini) for full-image reading.
- **Owner caught it (2026-10-26): photos were only 1080×1440.** `stream.capturePhoto` is a quick in-stream still; the sensor does
  4032×3024. Switched to the SDK's experimental **`camera.photo`** (`.full`, `.high`), following Meta's AGENTS.md and the BirdSpotter
  sample: start Photo once the stream is `.streaming`, stop the stream for each capture (frames and stills can't share the sensor),
  then restart the stream. It falls back to the in-stream capture if Photo isn't started. The timeout is 25 s, and transfer progress is logged. The zoom
  crop minimum is now 640 px (not a third of the image).
  **Run 9 (2026-10-26 22:11 UTC): 12 MP is too slow for live use.** The full photo was 1413 KB and arrived at **~23 KB/s** (first estimate said 45, which was wrong)
  (5% every ~3 s, a Bluetooth-like rate; the Wi-Fi link seems to go with the stream). That is **~30 s transfer plus ~4 s
  before it starts**, and video is off the whole time. The 25 s timeout gave up at 32%. Restarting the stream while Photo
  was still started gave `videoStreamingError`, which stopped the stream and left video dead for the rest of the session.
  **Fix:** default back to the quick 1080×1440 in-stream photo (~2 s). 12 MP is an opt-in setting ("12 MP photos (slow)"):
  stop stream → start Photo → capture (120 s timeout) → stop Photo → restart stream. An unexpected stream stop mid-session now
  restarts the stream. Untested. To try next: `.large`/`.medium` photo resolution, which may be a usable middle ground.
  **Open question: does the photo really leave Wi-Fi?** "Wi-Fi drops when the stream stops" is a guess from the speed. The
  public SDK has no transport control; it only reports `device.linkState` (connected/connecting/disconnected), and Meta's docs
  call video bandwidth "Bluetooth Classic". Added a **"Run photo speed test"** button: `camera.photo` full/high with the stream
  left running (keeps the link busy; Meta says they compete, untested), then medium/high, large/high and full/medium with the
  stream stopped. It logs size, seconds, KB/s, link state and the iOS Wi-Fi SSID before and after each, and saves images to
  `Documents/phototest/`. The app also shows live photo status ("Transferring 32% of 1413 KB · 12 s").
  **Speed test run 1 (22:21 UTC):** full/high with the stream running fails instantly (`captureFailure`), so Photo and stream
  can't overlap. medium/high = **1280x720**, 108 KB in 3.1 s (~35 KB/s), lower resolution than the quick photo. So `camera.photo`
  transfers at ~35–45 KB/s whatever the size, while the in-stream photo gets ~150 KB/s. The SSID check said "none" even while
  streaming, so iOS likely hides it and it proves nothing. The stream restart right after Photo stopped hit `videoStreamingError`
  again (the auto restart recovered in ~1 s); now waits 1 s first. The test loop quit when the camera object changed; fixed.
  **Speed test run 2 (22:23 UTC):** large/high = **1920x1080** (1080x1920 upright), 375 KB transferred in 18.2 s (~21 KB/s).
  full/medium and full/low **failed instantly** (`captureFailure`, cause unknown; full/high worked once, ~13 s after a stream start).
  Correction: the 12 MP run was also ~23 KB/s (5% of 1413 KB per 3 s), not 45, so a 12 MP photo needs **~60 s**.
  The first stream start after every Photo fails with `videoStreamingError` even after a 1 s wait; the auto restart recovers ~1 s later.
  After the test the SDK dropped video to 504x896.
  **Conclusion: `camera.photo` (SDK 1.0.1, experimental) moves ~20–25 KB/s at any size, too slow for live guidance.** Sizes:
  medium 1280x720, large 1920x1080, full 4032x3024. Keep it only for non-live use (e.g. S2 documentation photos sent in the background).
  Note: `camera.photo` returns **HEIC**, not JPEG (the test saved it with a .jpg name).
  **Is the quick photo detailed enough? Only for big text.** At arm's length (photo3 of 2026-10-25, crops in `tools/out/examples/`)
  "Walgreens", "Ibuprofen" and "100" are clear, but the small lines ("Ibuprofen tablets USP, 200 mg") are 6–8 px tall and smeared by
  compression. The large photo of the bag label is the same: barcode digits and description are mush. No model can read
  pixels that aren't there, so a stronger vision model alone won't fix this. Gains have to come from distance (2–3× closer =
  2–3× pixels, if the fixed-focus lens stays sharp up close) or from 12 MP (2.8× linear). The shutter fires within ~4 s (transfer starts then) and the
  ~60 s is transfer, so the user only has to hold still briefly.
  **Detail test (added 2026-10-26):** the speed-test button is now "Run photo detail test". Spoken cues (on-device TTS, `Speaker`)
  ask for quick photos at 40/25/15 cm, then one 12 MP photo at 25 cm (says "you can move" once the transfer starts). The guide is
  muted meanwhile. Files and OCR text go to `Documents/phototest/`. The OCR line count in the log is the readability score.
  **Detail test run 1 (22:34 UTC):** OCR lines: "40 cm" 2, "25 cm" 6 ("…TABLETS USP, 200 mG", "100 TABLETS"), "15 cm" 0. The owner says
  the distances may be off: the "25 cm" photo still looks like arm's length (label ~250 px wide). At "15 cm" the bottle was out of
  frame (only a hand). Cause: **the glasses have one camera, at the left front corner**, so a label centred in front of the face
  lands right of centre and leaves the frame up close. The cues now say "in front of your left eye". The 12 MP photo was transferring
  at ~85 KB/s (4%→18% in 2.4 s, faster than before) when **a stale 15 s timeout from the previous quick photo killed it**. Fixed:
  each wait has an id and only its own timer can end it.
  **Detail test run 2 (22:39 UTC), cues said "left eye": 12 MP wins.** OCR lines: quick ~40 cm 2, ~25 cm 4, ~15 cm 5 (the close one
  is soft, likely too close to focus), **12 MP at ~arm's length 14**: every label line ("IBUPROFEN TABLETS USP, 200 mg / PAIN
  RELIEVER / FEVER REDUCER (NSAID)") plus text on the monitor behind. 12 MP = 4032x3024 HEIC, 1114 KB. The shutter fired by 2.0 s,
  then it transferred at ~75 KB/s: **19.3 s total**, plus ~2 s for the video to come back. That's 3x the speed of the earlier
  ~23 KB/s runs, cause unknown (maybe link conditions), so keep a 120 s timeout. The 12 MP frame is landscape with a wider view.
  Crops are in `tools/out/examples/`.
  **Change: `take_photo` now defaults to 12 MP** (`detail: "full"`). `detail: "quick"` gives the 2 s photo for scene-level looks, and quick is
  also the fallback if 12 MP fails. When the shutter fires, an on-device voice says "Got it. You can move…" with the mic muted for the cue.
  HEIC originals are saved as .heic. The settings toggle "12 MP photos (~20 s, video off)" is on by default. Untested in a guide session.
  **Stale error banner (owner):** after the tests the app still showed "videoStreamingError" while video was moving. Cause: the
  first stream restart after every Photo failed (error shown), then the auto restart with a fresh camera worked, but the error was never
  cleared. Fix: after a photo, build a fresh camera directly (skip the restart that always failed), and clear a video error once
  streaming resumes. Settings label is now "Send a frame to the AI every N s" (the preview runs ~5 fps; that setting is only what
  the model sees). Untested.
  **Full-rate preview (owner asked, 2026-10-26):** compressed HEVC samples now go straight to an `AVSampleBufferDisplayLayer`
  (`VideoPreview.swift`), which decodes and draws them in hardware at the stream rate (~15 fps). `VideoDecoder` now builds only ~2
  UIImages/s, for the model and the photo fallback, down from 5. Untested on device: watch for a black or frozen preview, and
  whether it recovers after a photo or after backgrounding.
  **Guide session 23:17 UTC: failed.** The model called `take_photo` with detail "full" correctly, but (1) `camera.photo` returned
  `captureFailure` 0.1 s after the request (seen before on full/medium and full/low; cause unknown), and (2) the new fresh-camera
  restart threw `capabilityAlreadyActive` (the old camera was still active), so video stayed dead and later photos were refused.
  The video had also dropped to 504x896. Fixes: stop the old camera and wait for `.stopped` before `addCamera`; retry a capture that
  fails within 3 s once after 1 s; if video isn't back 6 s after a photo, do a full session restart. Untested.
  **Guide session 23:24 UTC: 12 MP works end to end.** Two 12 MP photos: **23.7 s** (58 KB/s) and **52 s** (21 KB/s). The speed varies
  run to run, cause unknown. Video came back every time (fresh-camera fix OK). OCR on the bag read "HOMOTEK 2 Pack Drive in Ball Catch
  with Strike Plate… Oil Rubbed Bronze, 13/15 inch" plus Code128 X002JSJ41B. On the bottle it read "IBUPROFEN TABLETS USP, 200 mg",
  "FEVER REDUCER (NSAID)", "100 TABLETS". It also picks up monitor text in the background.
  Model problems: (1) While photo 1 was transferring, the user spoke. The model re-called take_photo, got the "photo already in the
  conversation" reply, and said the label was "still blurry" before the photo arrived. (2) It undersold clean OCR text as "faint/low
  contrast". (3) For a new label it answered from video frames without a photo, then claimed it had used 12 MP mode.
  The owner disliked the on-device TTS cue ("weird tone").
  Fixes: a separate in-flight reply ("still being taken, tell the user it's coming"); prompt rules (each new label needs a new photo,
  never claim a photo you didn't take, trust clean OCR lines, ignore OCR from screens and background, photos take 20–60 s); the TTS
  cue is replaced by a two-note chime played through the guide's audio path, and the model says "Hold still until the chime." Untested.
  **Why the model reads worse than the iPhone's OCR:** Vision reads the full 4032x3024 image, while the model shrinks each image to
  ~512 px. Worse, our "close-up" was the union of ALL text, including the monitor behind, so it was 2465x2162 or 3087x2886 px, barely a
  close-up. **Fix (`PhotoReader`):** the main label is a window around the barcodes if any, else around the biggest letters (letter size =
  box height capped by width per character). Checked on both saved photos: close-ups of 1915x1129 (whole bag label) and 1046x972 (whole
  bottle label). OCR is split into "Main label" and "Other text in view", so screen text doesn't mix in. The OCR text stays the reliable
  source for fine print: even a good crop is ~2–4x downsized by the model. Old/new crops are in `tools/out/examples/`.
  **High-detail vision model (2026-10-26):** Azure CLI set up, and deployment `vision` = gpt-5.4-mini created (see `docs/setup/02-azure-setup.md`).
  `tools/vision_test.py` on the saved photos: bag → "HOMOTEK 2 Pack Drive in Ball Catch with Strike Plate for Closet Doors, Oil Rubbed
  Bronze, 13/16 Inch … Die Cast, Adjustable Tension Ball", 03258-53, T-DBC-001-OR, X002JSJ41B (5.2 s, 2.4k in tokens). Bottle → all
  lines, and it said the vertical side text was unreadable (4.1 s, 1.9k). It fixed OCR errors (13/15→13/16, garbage→"Pain Reliever").
  The app now calls it after every photo (`VisionClient`: whole photo at 2048 px + label close-up, detail high, reasoning low, the OCR
  text and the user's last words as the question). The answer goes in the function output as the most reliable reading; on failure the
  app carries on without it. Saved as `photoN-vision.txt`. Untested on device.
  **Guide session 23:45 UTC: the full pipeline works.** 12 MP transferred in **72.5 s** (16 KB/s, the slowest yet; stream stop alone took 3 s),
  the close-up was 641x641 on the main label, and vision answered in 4.9 s, reading the Expo whiteboard cleaner label in full (English and
  French steps, ASTM D-4238, www.expomarkers.com). The guide summarised it well.
  **Owner UX feedback:** "Hold still until the chime" is confusing because a long silence gives no sign anything is happening. Now: the guide says
  "Hold still for a few seconds. You'll hear beeps, then a chime when the photo is taken."; soft beeps every 0.7 s while capturing (skipped
  while the guide is talking); a chime when the shutter fires (first transfer progress); then the guide's own voice says "Photo taken.
  I'm processing it now; the answer can take up to a minute." That last line is an out-of-band response (`conversation: none`,
  `input: []`, audio only), verified word-for-word against Azure. Untested on device.
  **Large photo + vision model (desk test, 2026-10-26): not good enough.** On the bag label photographed at arm's length in `large/high`
  (1920x1080, ~250 KB): the whole photo gave "Home Depot / Hampton Bay-style label", barcode "K0D2J1X8B"; with a native-resolution label
  crop, "HOME DEPOT", barcode "X000J3J4A0". Both are **wrong** (it's HOMOTEK, X002JSJ41B), and the product description was unreadable.
  On-device Vision found no barcode either. The 12 MP photo of the same label read everything. So keep 12 MP: large saves transfer time
  but produces confident misreads. full/medium and full/low fail with captureFailure, so there's no middle size.
  **Tiered photos (owner, 2026-10-26):** "it may be fine with the video frames or the quick photo… then ask the user if needed for a higher
  res photo". `take_photo` now defaults to **quick** (1080x1440, ~2 s, still read by the vision model). The guide's tiers are video, then
  quick photo, then 12 MP, and it **asks before a 12 MP photo** ("Want me to take a sharper photo? It takes about a minute."). The quick
  photo's tool output nudges it to offer that if detail is missing. The "processing, up to a minute" line plays only for 12 MP. The vision
  prompt now forbids guessing brands or codes: re-run on the large bag photo, it said the codes were unreadable instead of inventing them.
  **Slow-transfer diagnostics:** each `camera.photo` capture logs `photo-diag before/after` (glasses battery, charging, thermal, worn,
  hinge, link; video resolution and fps before the stop, since the SDK drops to 504x896 when the link is congested; phone battery,
  low power, thermal, app state), `photo-diag transfer` (time to first byte, KB/s, slowest and fastest 3 s windows) and
  `photo-diag audio` (guide audio seconds and user utterances during the photo, audio route). Compare slow and fast photos. Untested.
  **Guide session 2026-10-27 00:27 UTC (laundry room, Samsung washer):** the quick photo plus vision worked ("Samsung front loader", model number
  unreadable, sensible cleaning steps). Problems: (1) **The shutter sound cut off the guide**: the tool call arrives while the guide's audio is
  still playing, so the capture fired mid-sentence. (2) The quick photo took **9 s** (usually ~2 s). (3) The guide **didn't offer a 12 MP photo**
  even though vision said the model number was unreadable. (4) At 00:28:58 the **glasses ended the session themselves** ("Session ended by
  device", user didn't stop it); cause unknown and there was no device-state logging. The app carried on with no video for 70 s and the model
  **claimed to see the view changing**. Fixes: the capture waits until the guide stops talking (+0.3 s); "quick photo took X s" is logged;
  if the vision answer says something is unreadable (or vision failed), the tool output tells the model to offer a 12 MP photo; on an
  unexpected session end the app tells the user and the model ("you can't see anything") and reconnects (10 tries, 3 s apart), then says
  "camera is back"; glasses state changes (worn, hinge, battery, thermal, link) are logged all session. Untested.
  **Session 00:35 UTC (same washer):** glasses 73% battery, worn, cool, connected; video **504x896 @ ~11 fps** the whole time (SDK
  congestion mode). (1) The quick photo **timed out at 15 s**: beeps, then nothing, so the user couldn't tell what happened or which kind of
  photo it was. The fallback 504x896 frame was useless. (2) The guide offered 12 MP (the nudge worked); the user said yes. The 12 MP
  transfer ran at **18 KB/s (12–24)**, first byte after 7.4 s, and the user stopped the session at 67% after ~1 min. (3) The live "Photo
  taken…" cue was **spoken twice**. (4) The guide answered "I still can't read it" mid-transfer (26 s of guide audio during the photo).
  **Diagnostic so far:** every slow or failed photo came with the video already degraded (504x896, ≤15 fps) before the photo, so the
  link was congested; the laundry room with metal appliances may matter. Keep comparing the `photo-diag before` video line against KB/s.
  **Fixes:** the app owns all photo cues, **pre-recorded in the guide's voice** (`tools/gen_cues.py` → `ios/SBSI/Resources/cues/*.pcm`,
  checked word for word): "Taking a photo. Hold still." / "Taking a high-resolution photo. Hold still for a few seconds.", then beeps,
  then chime + "Got it." / chime + "Got it, you can move. I'm processing the photo; this can take up to a minute.", or on failure a falling
  tone + "Sorry, the photo didn't come through." The guide no longer speaks before take_photo, and a system note at photo start says to
  only answer "still coming" until the result. Untested.
  **Session 00:42 UTC (printer at the desk):** quick photo 2.4 s; 12 MP **65 KB/s** (first byte 4.0 s, 23 s total) even though the video
  was 504x896 @ 18 fps beforehand. So degraded video does NOT reliably predict a slow transfer; location still looks likely (laundry room 18 KB/s).
  Owner: two greetings were heard (the app sends one; now logging every response start, and speech the server heard with no words, to
  catch an echo-triggered reply). Quick photos no longer beep unless they take more than 3 s. Owner: "it replies with reference to the
  first photo even when it knows a 2nd high-res photo is in progress". The second answer did come from the 12 MP photo but was no better:
  the "imageCLASS MF269dw" badge is visible in it, yet (a) the close-up framed the big "Canon" logo, and (b) vision got the photo at
  detail "high" (~1024x768).
  **Desk tests, gpt-5.4-mini:** detail "original" (full 4032x3024, ~3.4k tokens, 5–7 s) read "Canon imageCLASS MF269dw" (checked by eye;
  the badge is at the limit of legibility). Original + OCR + the Canon close-up said "MF244dw" (wrong: a wrong close-up misleads).
  Original + OCR, no close-up: the bag was correct twice (once 13/15 vs 13/16), the printer gave MF264dw (hedged) and MF269dw.
  **Change:** vision now gets the full-resolution photo at detail "original" plus the OCR text, and no close-up. Untested on device.
- **Printer run on device (session 2026-10-26_19-43-01, log 2026-10-27.log 02:43–02:47):** one greeting this time.
  Quick photos: vision said the badge was too blurry and the guide offered 12 MP (as designed). Both 12 MP transfers ran at **70 KB/s**
  (18 s and 15 s, first byte after 2–3 s) at the printer, with video at 504x896. Vision at full resolution: photo 2 said "looks like MF269dw,
  but I can't confirm"; photo 4 said "imageCLASS MF269dw" (middle digits a bit blurry), and the guide read it out correctly.
  **Issue:** on photo 2 the guide dropped the hedged reading and said only "too blurry" (the prompt said to believe "unreadable").
  It also later said "if you share the printer's model…" after reading it, and it can't look up instructions (no web access).
  **Change:** prompt now says to relay a hedged reading as likely, and to remember what it has already identified. Untested.
  Idea: a web/manual lookup tool for model-specific steps (see ideas.md).
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
