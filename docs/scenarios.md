# Scenarios

The use cases we're designing for. Each one drives requirements; add new ones at the bottom.
Status: 💡 idea · 🛠 in progress · ✅ demoed · 🔭 later (high-level thoughts only).

> **Current focus (2026-10-18): S1 — an individual fixing their own stuff (house, appliances,
> car, furniture…).** Business/technician scenarios (S2+) are captured as high-level thoughts
> for later; don't build for them yet, just avoid design choices that would block them.

---

## S1 — DIY: guided repair/maintenance of your own stuff 💡 ← CURRENT FOCUS

**Who:** an individual (non-expert) fixing or maintaining things they own: around the house,
appliances, furniture assembly, their own car.
**Examples:** open the hood and check the oil; replace a furnace filter; fix a leaky faucet;
reset a tripped GFCI; assemble flat-pack furniture.

> "Press the hood release lever, left of the steering wheel, near your knee."
> "Go outside. Lift the hood slightly with your left hand; with your right, feel under the
> center of the hood lip for the safety latch and push it sideways."

**Needs:**
- Step-by-step procedure for the specific make/model/year (from a procedure file or manual).
- Continuous frames to confirm each step ("hood is open — good, now find the prop rod").
- Proactive speech: AI speaks when a step is done or the user is doing it wrong.
- Safety warnings (hot engine, moving fan, jack stands).
- Hands-free only: voice in, voice out (Gen 2 has no display).

**First demo target:** hood release → prop hood → locate oil dipstick → check oil level.

---

## S2 — Professional technician: guided service + documentation for a work order 🔭 later

**Who:** a technician doing a job at a shop (e.g. camshaft cover reseal).
**Extra value vs S1:** documentation, not just guidance. Techs often know the steps but must
**document** the work, and that slows them down.

**Example voice commands during the job:**
> "Hey Guide, take a picture of this camshaft cover — I'm done resealing."
> "Note: gasket was cracked at the rear corner."
> "Log torque: cover bolts at 10 Nm."
> "What's the torque spec for these bolts?" (Q&A from service info)

**Needs:**
- **Photo capture on voice command**, tagged with the metadata needed to attach it to the
  **work order** (WO ID, vehicle, timestamp, procedure step, the tech's spoken caption, an
  auto-generated description). Capturing a photo does **not** attach it to the WO.
  - Photos go into a **staging area for review** linked to the WO. Some will be accidental
    or irrelevant.
  - **Post-processing review:** the technician or service manager decides what to keep
    (keep / discard / edit caption), and only approved photos are attached to the final WO.
  - The AI can help: pre-flag likely junk (blurry, duplicate, accidental, no relevant
    subject) and suggest which step/caption each photo belongs to. Humans make the final call.
  - **Review can happen in either place, at any time:** in the iPhone app (technician, during or
    right after the job) or in a **web dashboard** (service manager, later). Both edit the same
    review state, so photos and metadata must sync to a shared backend.
  - Keep discarded photos recoverable for a while (soft delete) unless shop policy says otherwise.
  - Implementation: the realtime model calls a tool like `capture_photo(label, note)` → app calls
    DAT `stream.capturePhoto(format: .jpeg)` (full-res still, better than stream frames) →
    saved to the work order.
  - Audible confirmation ("Photo saved: camshaft cover, after reseal") + shutter sound.
- **Voice notes / measurements** logged as structured entries (torque, part numbers, findings).
- **Work order model:** job ID, vehicle (VIN/make/model), steps done, photos, notes, parts,
  start/end time. Export to PDF/JSON first; later integrate with shop systems (DMS).
- Optional guidance mode: experienced techs may want "documentation only, speak only when
  asked", while juniors want full step-by-step guidance.
- Possibly flag missing evidence ("You haven't photographed the gasket surface before reseal").

**Open questions:**
- Wake phrase: "Hey Meta" belongs to Meta's assistant. Our app needs its own trigger (e.g.
  "Hey Guide"), or a session that is always listening once started (realtime voice activity detection), with
  the model deciding when speech is a command vs. chatter. Shop noise is a factor.
- Where work orders live: local on the phone first; later a backend (Azure) + shop system integration.
- Privacy/compliance: customer vehicle data, faces/plates in photos.

---

## Cross-scenario requirements (derived)

| Capability | S1 | S2 |
|---|---|---|
| Continuous frames + step verification | ✅ | ✅ (optional) |
| Proactive guidance | ✅ | configurable |
| Voice commands → app actions (tool calls) | basic | ✅ photo, note, measurement |
| High-res photo capture | — | ✅ |
| Photo staging + post-job review (keep/discard) | — | ✅ |
| Work order / session record + export | — | ✅ |
| Procedure files per task | ✅ | ✅ |

The AI layer must support **tool/function calling** (capture_photo, add_note, log_measurement,
next_step, …). Realtime APIs (OpenAI/Azure) support this; check it when evaluating open-weight
or on-device models.
