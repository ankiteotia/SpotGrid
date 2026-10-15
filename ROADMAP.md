# SpotGrid — Product Roadmap

> **One line:** SpotGrid is your home's memory. It tells you exactly where you kept
> something — in text, with a photo, and if needed with an AR arrow to the exact spot.
> Private, offline, and almost no typing.

This file is the single source of truth for *what we are building and in what order*.
Update the checkboxes as work lands. Technical design lives in
[`SpotGrid/Helpers/ARCHITECTURE.md`](SpotGrid/Helpers/ARCHITECTURE.md).

---

## 1. Product vision & USP

### The problem
"Passport kahan rakha tha?" Everyone loses things at home — documents, jewellery,
chargers, spare keys, medicines, warranty cards. Lists in Notes go stale, and memory fails.

### What already exists in the market
| Type | Examples | What they lack |
|---|---|---|
| List + photo + QR inventory apps | Sortly, Homebox, Encircle, Asset Vault, Keeper | Only say "Garage → Box 3". No guidance to the exact spot. Lots of typing. Many are cloud/account based |
| AR "find my stuff" apps | SpatialTags, Where Is My Stuff, Pixie (old, needed hardware tags) | Small, AR-only, slow when AR fails, no real organisation layer |

### Our USP — three pillars nobody combines
1. **Exact-spot answer.** Text + photo answer in 2 seconds ("Bedroom › Almirah drawer 2"),
   AR arrow for the last metre.
2. **Zero-effort capture.** On-device AI names things from photos, reads documents,
   and Siri can log "I kept the passport in drawer 3".
3. **Private by design.** No account, no server, no cloud. Your passport's location never
   leaves your device. Family sharing happens device-to-device.

### Target users (in priority order)
1. Households — documents, valuables, rarely used items.
2. Elderly people & people with low vision — spoken/haptic guidance (accessibility mode).
3. People moving house — box labels and "what's in box 4".
4. Later: small offices / shops (only if the home product works well).

---

## 2. Product principles (do not break these)

- **Offline first.** Nothing requires the network. No analytics SDKs.
- **Text + photo first, AR last.** The answer must be useful even if AR can't relocalize.
- **Spots are placed once in AR; items move freely without AR.**
- **Never lose history.** Moving an item records where it was before.
- **iPhone and iPad are both first-class.** Every screen must work in iPad portrait and
  landscape. LiDAR is an enhancement, never a requirement.
- **Minimum iOS 17.6** (intentional for this project). Newer APIs (e.g. iOS 26 Foundation
  Models) must be behind `#available` with a fallback.

---

## 3. Phases at a glance

| Phase | Theme | Outcome | Status |
|---|---|---|---|
| 0 | Base app (V1.1) | Scan, tag, save, AR locate | ✅ Done |
| 1 | **Foundation** | Spots, photos, move + history, daily-use basics | 🚧 In progress (`phase-1-foundation`) |
| 2 | Trust & safety | Change detection, re-anchor on new phone, backup, Face ID lock | ⏳ |
| 3 | Speed & reach | Siri, Spotlight, iPad split view, QR labels, widgets | ⏳ |
| 4 | On-device AI capture | Auto-naming, document OCR, natural-language search | ⏳ |
| 5 | USP "wow" features | Accessibility guidance mode, 3D dollhouse map | ⏳ |
| 6 | Family & life | Family sharing (no cloud), document expiry, lending, moving mode | ⏳ |
| 7 | Launch | Onboarding, Hindi + English, freemium, App Store | ⏳ |

---

## 4. Phase details

### Phase 0 — Base app (done)
- [x] RoomPlan scan (LiDAR) / manual mapping walk (non-LiDAR) on one shared `ARSession`
- [x] Tap-to-tag (LiDAR) and crosshair + tracked raycast placement (non-LiDAR)
- [x] `ARWorldMap` + SwiftData persistence, LZFSE compressed
- [x] Locate mode: relocalization, arrow, distance, off-screen chevron, haptics, arrival
- [x] Append items to an existing room, rename room, edit item name/notes

### Phase 1 — Foundation 🚧
**Goal:** make SpotGrid useful every day without opening AR.

**New data model:** `Room → Spot → Items`, plus per-item location history.
- A **Spot** is a physical place tagged once in AR (e.g. "Almirah drawer 2"). It owns the
  AR anchor and an automatic photo of the place.
- An **Item** lives in a spot. Items can be added, moved, and deleted without AR.
- A **LocationEvent** records every time an item is placed or moved.

Checklist:
- [ ] `SpotModel` + `LocationEvent` SwiftData models; items belong to spots
- [ ] Automatic upgrade of old data (each old item becomes its own spot; old `asset:` AR
      anchors keep working)
- [ ] AR tagging creates **spots** (spot name + optional list of items in it)
- [ ] Automatic spot photo captured at the moment of tagging (correct orientation on
      iPad landscape too)
- [ ] Item photos from camera or photo library (camera only outside AR, so the AR
      session is never interrupted)
- [ ] Room screen shows spots with photos and item counts
- [ ] Spot screen: photo, items, add item without AR, rename, delete, "Guide me"
- [ ] Item screen: photo, name, notes, location breadcrumb, move to another spot,
      history, "originally at…" with "Guide me to old spot", delete
- [ ] "Still here ✓" confirmation and "last confirmed" date (also set by *Found It*)
- [ ] Search matches item name, notes, spot name and room name; results show photo +
      "Room › Spot" instantly; AR is one tap away instead of automatic
- [ ] Locate mode targets a spot; on arrival shows the "before" photo of the spot so
      the user can compare by eye
- [ ] Unit tests for pure logic (anchor naming, image orientation, distance formatting)

**Done when:** you can tag a drawer once, then add/move/remove items in it for weeks
without opening AR, and search answers "where is X" with a photo in one tap.

### Phase 2 — Trust & safety
**Goal:** users can rely on SpotGrid for important things.
- [ ] **Automatic change detection:** on arrival, compare the live camera view with the
      saved spot photo using Vision feature prints → "This spot looks different — the item
      may have been moved". Thresholds must be calibrated on real devices.
- [ ] **Re-anchor flow:** when a room can't be recognised (new phone, renovated room),
      re-scan and re-place each spot by matching its saved photo. Items/history stay.
- [ ] **Relocalization timeout UX:** after ~20 s show the photo + text answer and tips
      instead of an endless "Finding your room".
- [ ] **Backup / restore:** export everything (rooms, spots, items, photos, maps) to a
      single file in Files; import it back. Works offline (USB, AirDrop, any drive).
- [ ] **Private items:** mark items as private; Face ID / passcode needed to see them.

### Phase 3 — Speed & reach
**Goal:** answer "where is X" without even opening the app.
- [ ] **Siri & Shortcuts (App Intents):** "Where is my passport?" → spoken answer + photo
      snippet. "Open SpotGrid search".
- [ ] **Spotlight:** index items so they show in iPhone/iPad search.
- [ ] **iPad layout:** `NavigationSplitView` (rooms | spots/items | detail), keyboard
      shortcuts (⌘F search, ⌘N new room), drag & drop an item onto a spot to move it.
- [ ] **QR labels:** print a QR code per spot/box; scanning it opens the spot or moves
      the current item there. (QR, not NFC — iPads have no NFC.)
- [ ] **Widgets:** recent items / quick search (needs a new widget extension target —
      do this in Xcode).

### Phase 4 — On-device AI capture
**Goal:** almost no typing.
- [ ] Suggest item names from the item photo (Vision image classification).
- [ ] Read text from documents/labels (Vision OCR) and make it searchable.
- [ ] Natural-language search ("the blue file with the electricity bill") using Apple's
      on-device Foundation Models on iOS 26+ with Apple Intelligence; keyword search
      fallback everywhere else.
- [ ] Voice logging via Siri: "I kept the passport in drawer 3" → item moved + history.

### Phase 5 — USP "wow" features
**Goal:** features that make SpotGrid memorable and App Store-feature-worthy.
- [ ] **Accessibility guidance mode:** spoken directions ("drawer is 2 metres to your
      left"), spatial-audio beacon at the spot, stronger haptics, full VoiceOver support.
- [ ] **3D dollhouse map (LiDAR):** merge room scans into one home model
      (RoomPlan `StructureBuilder`) and pin spots on it; tap a pin to see items.
- [ ] **2D floor plan** from saved `capturedRoomData` with spot dots (iPad shines here).
- [ ] *Experiment:* recognise specific objects/images in AR (`ARReferenceObject` /
      `ARReferenceImage`) to suggest "Passport seen here — update location?".

### Phase 6 — Family & life
- [ ] **Family sharing without cloud:** send a room (map + spots + items + photos) to a
      family member's iPhone/iPad over local Wi-Fi/Bluetooth (MultipeerConnectivity).
- [ ] **Documents vault:** expiry dates and reminders (passport, insurance, warranty),
      attach bill/warranty photos.
- [ ] **Lending tracker:** "Drill → Rahul, 12 Oct" with a reminder to get it back.
- [ ] **Moving mode:** boxes with QR labels, "what's in box 4", unpack and re-tag.

### Phase 7 — Launch
- [ ] Onboarding (what a spot is, how to scan, LiDAR vs non-LiDAR tips)
- [ ] Hindi + English localisation (String Catalog)
- [ ] StoreKit 2 freemium — Free: 1 room, limited items. Pro: unlimited rooms, family
      sharing, AI features, dollhouse map. Test both one-time purchase and subscription.
- [ ] Privacy nutrition label: "Data Not Collected"
- [ ] App Store screenshots (iPhone + iPad), preview video, TestFlight beta
- [ ] Consistent naming: replace leftover "MicroLocator" / "Spatial Organizer" with SpotGrid

---

## 5. Risks & how we handle them

| Risk | Mitigation | Phase |
|---|---|---|
| AR relocalization is slow or fails | Text + photo answer first; timeout UX; reference photo | 1, 2 |
| New phone can't load old AR maps | Re-anchor flow; data never depends on AR alone | 2 |
| Users stop tagging after a week | Spots (tag once), AI naming, Siri logging | 1, 4 |
| Phone lost = data lost (offline app) | Backup / restore to Files | 2 |
| Non-LiDAR placement accuracy | Crosshair + tracked raycast + 2.5 m gate (done) | 0 |

---

## 6. Testing matrix

Everything AR must be checked on real hardware (the simulator has no camera/ARKit):

| Device class | Capture path | Notes |
|---|---|---|
| iPhone Pro (LiDAR) | RoomPlan + tap placement | Main path |
| iPhone non-Pro | Mapping walk + crosshair | Check plane detection in dim rooms |
| iPad Pro (LiDAR) | RoomPlan + tap placement | Test landscape + portrait, Split View |
| iPad (non-LiDAR) | Mapping walk + crosshair | No haptics on most iPads — UI must not rely on them |

---

## 7. Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-10-15 | Minimum iOS 17.6 | SwiftData, RoomPlan shared `ARSession` (iOS 17) are core |
| 2026-10-15 | Introduce Spots (Room → Spot → Items) | Tag once in AR, manage items without AR |
| 2026-10-15 | Keep `asset:<uuid>` anchors readable forever | Old saved rooms must keep working after upgrade |
| 2026-10-15 | Camera for item photos only outside AR | Opening the camera interrupts the shared `ARSession` |
| 2026-10-15 | Automatic change detection moved to Phase 2 | Vision similarity thresholds need real-device calibration |
