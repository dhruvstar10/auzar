# Blog notes

Findings worth writing up publicly. Add as we go.

- Meta's built-in Live AI feels snapshot-based for guided tasks: it answers about the current
  frame when asked but doesn't follow progress or speak up proactively. Motivation for building
  our own.
- Realtime LLM APIs don't really "watch video" — every current multimodal model consumes
  sampled still frames. "Live" behavior is an app-design problem (frame cadence, context
  trimming, proactive triggers, step state), not just a model problem.
- Gotcha: on iOS, Meta's DAT camera stream rides a Wi-Fi Direct link the phone joins via
  `NEHotspotConfiguration`. A free Apple "Personal Team" can't sign the Hotspot entitlement, so
  sessions connect (BLE) but the preview fails with a misleading "Device is not connected".
  Budget $99/yr for the Apple Developer Program from day one.
- Phone-in-pocket works: Meta's CameraAccess sample deliberately kills the session on
  background, and its Info.plist lacks the `external-accessory` background mode. Remove the
  background stop, add `external-accessory` + `UISupportedExternalAccessoryProtocols:
  com.meta.ar.wearable`, and the 720p/24fps stream keeps flowing with the iPhone locked.
- Stream is a true 720×1280 @ 24 fps but visibly soft (compression). Use stills for fine detail.
- Azure `gpt-realtime-2.1-mini` accepts images over the realtime WebSocket: one frame ≈ 323
  input tokens, ~2 s to first spoken audio for an image + question. So frame cadence, not
  resolution, drives cost. Sending 1 frame every 2 s ≈ 10k image tokens/min before trimming.
