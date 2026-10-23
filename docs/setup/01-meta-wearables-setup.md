# 01 — Meta Wearables setup (glasses + Developer Mode + SDK)

Goal: get to the point where our own iOS app can stream the glasses' camera.
Source: Meta DAT docs (checked 2026-10-18). Re-verify versions — they change often.

Status legend: [ ] todo · [x] done · record findings inline.

## A. Mac / Xcode

- [x] Xcode installed (`/Applications/Xcode.app`).
- [x] Xcode **26.6** (build 17F113) confirmed.
- [ ] Command-line tools still point at CommandLineTools (`sudo` can't prompt inside Claude
      Code). Options: (a) Xcode → Settings → Locations → Command Line Tools → pick Xcode 26.6
      (GUI password prompt), or (b) run the `sudo xcode-select -s …` command in Terminal.app.
      **Workaround for agents:** prefix commands with
      `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (verified working).
- [x] iOS platform installed: **iOS SDK 26.5** + simulator.
- ⚠️ iPhone is on **iOS 27.0.1** but Xcode 26.6 ships the iOS 26.5 SDK. If Xcode reports the device
      as unsupported, update Xcode (App Store) to a version that supports iOS 27.
- [ ] Open Xcode once, accept license, install the iOS platform/simulator when prompted.
- [x] Xcode → Settings → Accounts: sign in with your Apple ID (a free account works for
      running on your own iPhone; paid $99/yr Apple Developer account only needed for
      TestFlight / sharing with others / longer-lived provisioning).

## B. iPhone

- [x] iOS 15.2+ (DAT minimum; CameraAccess sample needs 17.2+). Installed: **iOS 27.0.1**
- [ ] Enable Developer Mode on iPhone (appears after first Xcode run to the device):
      Settings → Privacy & Security → Developer Mode.

## C. Glasses + Meta AI app

- [x] Glasses model: **Ray-Ban Meta Gen 2, Wayfarer (07P5)** (supported by DAT; camera + mic + open-ear speakers, no display).
- [ ] Update **Meta AI app** to the version required by the SDK release we use.
      SDK 1.0.0 → Meta AI app **V290+**. Installed: **294.1.0.28.163** ✅
- [ ] Update **glasses firmware**. SDK 1.0.0 → **V128+**.
      Check: Meta AI app → Devices tab → your glasses → ⚙ Device settings → General → About → Version.
      Installed: **V129** (release 129.0.1.23.378) ✅
- [ ] Glasses paired and connected in the Meta AI app.
- [ ] **Enable Meta AI Developer Mode**: in the Meta AI app → Settings → App Info → tap
      **App version** 5 times → toggle **Developer Mode** → Enable.
      Afterwards, dev apps show under Meta AI settings → App connections → Developer mode apps.

Developer Mode lets an unpublished app register with the glasses **without** a Meta App ID /
client token, which is all we need for personal testing.

## D. Meta Wearables Developer Center (can come later)

Only needed for a non-Developer-Mode build, release channels (sharing with testers), or
eventual publishing. Not a blocker for the first prototype.

- [ ] Onboard / create organization: https://wearables.developer.meta.com/
      (docs: https://wearables.developer.meta.com/docs/onboarding-and-organization-management)
- [ ] New project → Configuration → add iOS app details (bundle ID) → copy
      **Wearables Application ID** (+ client token) into a gitignored `Secrets.xcconfig`.
- Note: App Store publishing is not currently supported (SDK uses ExternalAccessory);
  distribution is via Meta release channels / TestFlight to testers.

## E. SDK smoke test (Claude/agent can do most of this)

- [ ] Clone and run Meta's iOS sample app: https://github.com/facebook/meta-wearables-dat-ios/tree/main/samples
- [ ] Try **MockDeviceKit** first (no glasses needed), then real glasses.
- [x] Confirm: registration via Meta AI app round-trip works, camera permission granted,
      stream reaches `.streaming`, frames render. ✅ **2026-10-20: live video from Gen 2 glasses on iPhone.**
- [x] Measure fps/resolution: 720×1280 @ 24 fps with `.high` (via the Wi-Fi Direct link).
- [ ] Measure glasses + phone battery drain over 10–30 min of streaming.
- Optional: add Meta's Wearables MCP server to the AI coding tool
  (`https://mcp.developer.meta.com/wearables`) so agents can query current SDK docs.

## Integration cheat sheet (for the agent building `ios/`)

- SPM: `https://github.com/facebook/meta-wearables-dat-ios` → `MWDATCore`, `MWDATCamera`.
- Info.plist: `CFBundleURLTypes` (callback scheme), `MWDAT` dict (`AppLinkURLScheme`,
  `MetaAppID` [not needed in Dev Mode], `ClientToken`, `TeamID`), `UIBackgroundModes` →
  `bluetooth-central`, `NSBluetoothAlwaysUsageDescription`, `NSLocalNetworkUsageDescription` +
  `NSBonjourServices` (`_bonjour._tcp`, needed for Wi-Fi streaming), `NSCameraUsageDescription`.
- Flow: `Wearables.configure()` → `startRegistration()` + `handleUrl(url)` →
  `requestPermission(.camera)` → `createSession(deviceSelector: AutoDeviceSelector())` →
  `session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .low|.medium, frameRate: …))`
  → `videoFramePublisher` → `frame.makeUIImage()`.
- Frame rates: 2/7/15/24/30. Resolutions: low 360×640, medium 504×896, high 720×1280.
  SDK may drop resolution then fps (not below 15) under BT bandwidth pressure.
- Only one session per device at a time. Avoid `DeviceStateSession` alongside a camera stream
  (known issue). Streams started off-head pause when glasses are put on.

## F. Local SDK checkout (2026-10-18)

- Meta's SDK repo cloned **outside Google Drive** to `~/code/meta-wearables-dat-ios`
  (commit bbae597, SDK **1.0.1**, 2026-10-09). Keeping git repos out of Drive avoids sync corruption.
- First thing to run: `samples/CameraAccess/CameraAccess.xcodeproj` (no new Xcode project needed).
  Sample needs **iOS 17.2+, Xcode 26.4+, Swift 6.3+**. Developer Mode needs no Meta credentials;
  just set your Apple team and a unique bundle ID (e.g. `com.dhruvgoel.CameraAccess`).
- The repo also ships AI-agent skills (`install-skills.sh`, `plugins/`, `AGENTS.md`). Worth reading
  before writing our own app.

- [x] 2026-10-18: CameraAccess **builds for the simulator** from the CLI (Xcode 26.6, unsigned):
      `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
- 2026-10-18: Signing with a **free Personal Team** fails: "Personal development teams … do not
  support the Access Wi-Fi Information and Hotspot capabilities." The sample's entitlements
  request `networking.wifi-info` + `networking.HotspotConfiguration`. We removed both to get a
  build signed. ⚠️ **That was wrong for streaming. See the correction below.**
- 2026-10-18: After removing the two capabilities, signed device build + install works from CLI
  (free Personal Team, iPhone 17 Pro on iOS 27.0.1, Xcode 26.6 — no Xcode update was needed):
  ```
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcrun devicectl list devices                      # get device id
  xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess \
    -destination 'id=<DEVICE_ID>' -allowProvisioningUpdates build
  xcrun devicectl device install app --device <DEVICE_ID> \
    ~/Library/Developer/Xcode/DerivedData/CameraAccess-*/Build/Products/Debug-iphoneos/CameraAccess.app
  ```
  The "Developer App" trust entry in iPhone Settings only appears after the first install.
  Free-team provisioning profiles expire after 7 days → just rebuild/reinstall.
- 2026-10-18: First session start → "App on glasses needs an update before this session can
  start." The glasses run a separate small **DAT app component** besides the firmware (SDK event
  `DeviceSessionError.datAppOnTheGlassesUpdateRequired`; API `wearables.openDATGlassesAppUpdate()`).
  - The Meta AI app (v294) has **no update button** for this. Its menu is "Apps" (not "App
    connections"), and tapping CameraAccess only offers Disconnect.
  - **Sample bug (SDK 1.0.1):** `WearablesViewModel.openDATGlassesAppUpdate()` exists but no UI
    calls it. We patched our local copy (`CameraViewModel.glassesAppUpdateRequired` + an
    "Update app on glasses" button in the error alert in `CameraView.swift`). Our own app must
    handle this error the same way. Possibly worth reporting upstream.
  - `openDATGlassesAppUpdate()` opens Meta AI app → Settings → **App Info** (the same page as the
    Developer Mode toggle). In Developer Mode it lists each pair of glasses with an **Install**
    button ("RB Meta 07P5 — Install"). That installs the DAT component on the glasses. **You can
    also go there directly**: Meta AI → Settings → App Info.

- 2026-10-18 **CORRECTION: camera streaming needs the Hotspot entitlement → paid Apple
  Developer Program ($99/yr) is REQUIRED.** With the capabilities removed, session start works
  (BLE) but `Preview` fails with "Device is not connected: <id>". `nm -u MWDATCore` shows the SDK
  imports `NEHotspotConfiguration`/`NEHotspotConfigurationManager`/`NEHotspotNetwork` and has
  `CreateWifiDirectNetwork`/`JoinWifiDirectGroup` messages: **video goes over a Wi-Fi Direct
  link from the glasses that the phone joins via NEHotspotConfiguration.** (The earlier "not
  referenced" conclusion came from a broken BSD-grep pattern.) Free Personal Teams can't get that
  entitlement. Next: enroll in the Apple Developer Program, restore both capabilities
  (`git checkout samples/CameraAccess/CameraAccess/CameraAccess.entitlements` in
  `~/code/meta-wearables-dat-ios`, then re-add them in Signing & Capabilities if Xcode removed
  them from the target), and switch the Team to the paid team.
- Also: tapping the glasses touchpad toggles the session to **paused** (touchpad = play/pause input).
- 2026-10-20: **Paid Apple Developer Program active.** Same team ID as the free personal
  team (upgraded in place; Xcode → Settings → Apple Accounts now shows "Dhruv Goel — Admin").
  Xcode's cached `defaults` still says "Personal Team", so don't trust it. Restored the entitlements
  file; signed build now contains `networking.HotspotConfiguration` + `networking.wifi-info`
  (verified with `codesign -d --entitlements :-`). Reinstalled on iPhone.

- 2026-10-20: ✅ **First live stream works** (paid team, sample at `.low` 360×640 @ 24fps, hvc1).
  Observations:
  - Smooth but **not sharp**. The sample requests `StreamingResolution.low`.
  - **iOS asks to join the glasses' Wi-Fi on every Preview.** The SDK sets up the Wi-Fi Direct
    link via NEHotspotConfiguration per stream. Likely unavoidable; check whether keeping one stream alive
    (vs. stop/start) avoids repeat prompts.
  - **Locking the phone stopped the session.** The sample does this on purpose
    (`handleDidEnterBackground` → `endSession()`), so it's not proven to be an SDK limit.
  - Experiment build: `.high` (720×1280) + `keepStreamingInBackground = true` flag in
    `CameraViewModel`, plus `[SBSI]` diagnostics (`sbsiLog()` → stdout + Documents/sbsi.log).
    Capture logs with: `xcrun devicectl device process launch --console --terminate-existing
    --device <ID> com.dhruvgoel.CameraAccess > log.txt` (NSLog does NOT reach `--console` on iOS; use print).
  - **Measured (2026-10-20):** stream delivers a true **720×1280 @ ~24 fps** with `.high`. The
    owner still sees it as "not sharp" → it's encoder compression, not the resolution setting.
    For fine detail (labels, part numbers), use the high-quality still photo capture (`Camera.photo`).
  - **On lock:** our app did NOT stop. ~0.3 s after `didEnterBackground`, the SDK reported
    `unexpectedError("Session ended by device")`. The sample's Info.plist lacks the `external-accessory`
    background mode + `UISupportedExternalAccessoryProtocols: [com.meta.ar.wearable]`, which the
    SDK's AGENTS.md says the camera's Bluetooth Classic link needs. Added both.
    ✅ **Retest 2026-10-20: streaming continues with the phone locked.** Frames kept arriving
    at 720×1280 @ ~24 fps for the full ~18 s lock, and the preview was live on unlock.
