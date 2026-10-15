# Micro-Location Spatial Organizer — Architecture Blueprint

A 100% offline iOS utility that lets users scan a room (RoomPlan), tag the physical
location of items with AR anchors (ARKit + RealityKit), persist everything locally
(SwiftData + `NSKeyedArchiver`), and later relocalize into the saved world map to be
guided by a floating 3D arrow to the exact spot.

---

## 1. Platform requirements

| Requirement | Why |
|---|---|
| iOS 17.0+ | SwiftData, `RoomCaptureView(frame:arSession:)`, `RoomCaptureSession.stop(pauseARSession:)`, two-parameter `onChange`, `ContentUnavailableView` |
| LiDAR device (optional) | Enables the RoomPlan-assisted flow + mesh-precise raycasts. Non-LiDAR devices use the manual-mapping fallback (§8) — the app's true floor is plain ARKit world tracking, present on every iOS 17 device |
| `NSCameraUsageDescription` | The only Info.plist key needed. Suggested copy: *"The camera is used to scan your room and locate tagged items in augmented reality."* |
| No network | Nothing in this app touches the network. `ARWorldMap`, RoomPlan output, and SwiftData all live on-device |

The app runs on **all** iOS 17 devices. LiDAR hardware selects the richer
capture path (`DeviceCapabilities.captureStrategy`); non-LiDAR devices take the
manual-mapping fallback described in §8. The `ContentUnavailableView` gate now
only fires for the (practically nonexistent) case of a device without ARKit
world tracking.

---

## 2. The core architectural problem

The naïve design — "scan the room, then open an AR view and place anchors" — fails
silently, because **RoomPlan and a subsequently created AR session have different
world origins**. Coordinates captured in session B are meaningless in the map from
session A.

The entire architecture is organized around solving this once, correctly:

### 2.1 One shared `ARSession` for the whole capture flow (iOS 17 pattern)

```
        ┌────────────────────  shared ARSession (single world origin)  ───────────────────┐
        │                                                                                  │
  RoomCaptureView(arSession:)        stop(pauseARSession: false)         ARView.session =  │
  RoomPlan scans the room     ──▶    session keeps tracking       ──▶    same session      │
                                                                         user taps to tag  │
        │                                                                                  │
        └───────────────  getCurrentWorldMap() → one map containing the anchors  ──────────┘
```

1. The `ScanAndTagCoordinator` owns `let arSession = ARSession()`.
2. That session is injected into `RoomCaptureView(frame:arSession:)`.
3. When the user finishes scanning, we call `captureSession.stop(pauseARSession: false)`
   — the RoomPlan UI goes away, **but world tracking never stops**.
4. A RealityKit `ARView` is attached to the *same* session. Two things are mandatory:
   - `arView.automaticallyConfigureSession = false` — otherwise ARView runs its own
     fresh configuration on `didMoveToWindow` and destroys the world origin.
   - Re-run our own `ARWorldTrackingConfiguration` **without** `.resetTracking` /
     `.removeExistingAnchors`, so tracking state and origin are preserved.
5. Taps raycast against the LiDAR scene mesh; each confirmed item becomes a **named
   `ARAnchor`** added to the session.
6. Only then do we call `getCurrentWorldMap()` — the map that gets archived already
   contains every item anchor, in the same coordinate space as the scan.

This handoff is the officially supported custom-`ARSession` RoomPlan flow introduced
in iOS 17 (WWDC23, *"Explore enhancements to RoomPlan"*).

### 2.2 Dual persistence: anchors in the map, coordinates in SwiftData

| Store | Contains | Role |
|---|---|---|
| `ARWorldMap` (archived `Data`) | Feature points + named `ARAnchor`s (`asset:<UUID>`) | **Spatial source of truth.** ARKit refines anchor transforms during relocalization — raw floats can't benefit from that |
| SwiftData `StoredAsset` | name, notes, date, x/y/z | **Search index + metadata + fallback.** Drives the global search bar; if a named anchor fails to resurface, the arrow is placed at these coordinates |

Anchor identity is the bridge: `ARAnchor.name == "asset:" + StoredAsset.id.uuidString`
(see `AnchorNaming`). On relocalization, `session(_:didAdd:)` delivers restored
anchors and we match by name.

### 2.3 Locate mode is a relocalization-first UX

```
Load room ──▶ unarchive ARWorldMap (background task; maps are 10–60 MB)
          ──▶ config.initialWorldMap = map
          ──▶ session.run(config, options: [.resetTracking, .removeExistingAnchors])
          ──▶ STATE: relocalizing → user is told to pan around where they started scanning
          ──▶ cameraDidChangeTrackingState → .normal  (relocalized!)
          ──▶ session(_:didAdd:) delivers restored anchors → match target by name
          ──▶ mount arrow entity, STATE: guiding
          ──▶ (fallback: if no anchor within a few seconds, place at stored x/y/z)
```

Relocalization only succeeds when the camera sees geometry it recognizes from the
original scan. The UI holds the user in an instruction state until ARKit reports
`.normal` — pretending guidance works before that point produces arrows floating in
garbage coordinates.

### 2.4 Guidance rendering

A single `SceneEvents.Update` subscription (per-frame, main thread) drives:

- **3D arrow** — custom cone mesh (built via `MeshDescriptor`, double-sided so
  winding can never bite), `UnlitMaterial` so it's visible in any lighting, bobbing
  + spinning above the exact point, with a translucent ground ring on the point itself.
- **Distance pill** — `simd_distance(cameraTransform.translation, target)`, formatted
  cm/m.
- **Off-screen chevron** — target transformed into camera space; if behind the camera
  or outside the viewport, a screen chevron rotates toward it
  (`atan2(-camY, camX)`, flipped when behind).

Occlusion is deliberately **off** for guidance entities: an arrow hidden behind the
cupboard it points into defeats the purpose.

---

## 3. Module map & folder structure

```
MicroLocator/
├── App/
│   └── MicroLocatorApp.swift            @main, ModelContainer([RoomModel, StoredAsset])
├── Core/
│   ├── Persistence/
│   │   ├── RoomModel.swift              @Model — id, name, scannedDate, worldMapData (external),
│   │   │                                capturedRoomData (external), cascade → assets
│   │   ├── StoredAsset.swift            @Model — id, name, notes, dateAdded, x/y/z, room
│   │   └── ARPersistenceManager.swift   captureWorldMap(from:) with mapping-status gate,
│   │                                    archive/unarchive (NSKeyedArchiver + LZFSE),
│   │                                    trackingConfiguration(initialWorldMap:)
│   └── Spatial/
│       ├── SpatialSupport.swift         AnchorNaming, DeviceCapabilities,
│       │                                WorldMappingStatus display helpers
│       └── EntityFactory.swift          itemMarker(), guidanceArrow(), targetRing(),
│                                        MeshDescriptor cone generator
├── Features/
│   ├── RoomList/
│   │   └── RoomListView.swift           Landing page, @Query rooms, .searchable global
│   │                                    item search (#Predicate localizedStandardContains),
│   │                                    RoomDetailView, LiDAR gate
│   ├── Capture/
│   │   ├── ScanAndTagCoordinator.swift  Phase state machine, owns the shared ARSession,
│   │   │                                RoomCaptureSessionDelegate + ARSessionDelegate,
│   │   │                                tap→raycast→anchor, saveRoom()
│   │   ├── RoomCaptureViewRepresentable.swift   RoomCaptureView(frame:arSession:)
│   │   ├── PlacementARViewContainer.swift       ARView on shared session + tap gesture
│   │   └── ScanFlowView.swift           scanning → processing → tagging → saving UI,
│   │                                    TagItemSheet, SaveRoomSheet
│   └── Locate/
│       ├── LocateCoordinator.swift      map load, relocalization tracking, anchor match,
│       │                                fallback placement, per-frame guidance math
│       └── LocateView.swift             Full-screen ARView + state overlays
```

Dependency direction: `Features → Core`, never sideways between features. Both AR
flows depend only on `ARPersistenceManager`, `EntityFactory`, and `SpatialSupport`,
so extracting `Core/` into a local SPM package later is a file move, not a refactor.

---

## 4. End-to-end data flows

### Capture flow

```
RoomListView (+) 
  └▶ ScanFlowView (fullScreenCover)
       phase .scanning      RoomCaptureViewRepresentable on coordinator.arSession
       [Finish Scan]        captureSession.stop(pauseARSession: false)
       phase .processing    RoomBuilder.capturedRoom(from:) (async)
       phase .tagging       PlacementARViewContainer (same session, no reset)
                            tap → raycast(.estimatedPlane, .any) → TagItemSheet
                            confirm → ARAnchor(name: "asset:<uuid>") → session.add
                            didAdd → AnchorEntity(anchor:) + itemMarker()
       [Save Room]          gate: worldMappingStatus ∈ {mapped, extending}
       phase .saving        getCurrentWorldMap → NSKeyedArchiver → LZFSE
                            RoomModel + StoredAssets → ModelContext.save()
       phase .saved         dismiss
```

### Locate flow

```
Search bar → StoredAsset → LocateView(room:asset:) (fullScreenCover)
  loadingMap → relocalizing → (tracking .normal) → searchingAnchor
    → didAdd matches "asset:<uuid>" → guiding
    → else 4 s timeout → fallback AnchorEntity(world: stored x/y/z) → guiding
  per frame: arrow bob/spin, distance pill, off-screen chevron
```

---

## 5. Swift 6 / strict-concurrency posture

- Coordinators are `@MainActor` `ObservableObject`s. `ARSession` delivers delegate
  callbacks **on the main queue when `delegateQueue == nil` (the default)**, so
  delegate methods are declared `nonisolated` and hop in with
  `MainActor.assumeIsolated` — zero dispatch overhead, honest about isolation.
- `RoomCaptureSessionDelegate` makes no queue guarantee → callbacks wrap work in
  `Task { @MainActor in … }`.
- `ARWorldMap`, `ARFrame`, `CapturedRoomData` are not `Sendable`. Files that ferry
  them across isolation use `@preconcurrency import ARKit` / `RoomPlan` with comments
  at each crossing explaining why it's safe (single reader, value handed off once).
  This is the same pragmatic posture you'd use mid-migration on a production target.
- Never retain `ARFrame` beyond the delegate callback — we read
  `worldMappingStatus` synchronously and let the frame go.

---

## 6. Failure modes & mitigations

| Failure | Mitigation |
|---|---|
| Map too large / archive slow | LZFSE compression (~50%), `@Attribute(.externalStorage)` keeps blobs out of the store file, unarchive on a background task |
| Relocalization never converges (lighting changed, furniture moved) | Explicit relocalizing state with instructions; the user can always fall back to notes text. Long-term fix is a "re-scan room" flow |
| Named anchor missing after relocalization | 4-second fallback places the arrow at the SwiftData x/y/z mirror |
| User taps empty air while tagging | Raycast miss is surfaced as a transient hint, no anchor created |
| Save attempted with `worldMappingStatus == .limited` | `captureWorldMap` throws `mappingIncomplete`; UI reverts to tagging with an alert telling the user to look around more |
| Room rescanned later | A new scan is a **new world map** — old anchors are invalid in it. V1 treats rooms as immutable snapshots; "add items to existing room" would relocalize into the saved map first, then tag (same Locate machinery, then re-save the map) |

## 7. Deliberate V1 scope cuts (documented, not forgotten)

- `CapturedRoom` is persisted (`capturedRoomData`, it's `Codable`) but not yet
  rendered — it's the seed for a future 2D floor-plan minimap with item dots.
- No occlusion on guidance entities (see §2.4).
- No multi-item simultaneous guidance; Locate targets one asset (others could render
  as dim markers from the same `didAdd` stream).
- No CloudKit — offline is a feature here, and `ARWorldMap`s are device-class
  sensitive anyway.

---

## 8. Non-LiDAR fallback (capture strategy matrix)

RoomPlan is the only LiDAR-hard dependency in the app, and it only produces the
(not-yet-rendered) structural room model. Everything load-bearing —
`ARWorldTrackingConfiguration`, plane detection, `ARWorldMap` persistence and
relocalization, named anchors, RealityKit guidance — is ARKit 2-era technology
that runs on every device capable of installing iOS 17 (floor: A12 / iPhone XS).

`DeviceCapabilities.captureStrategy` selects one of two capture paths at the
top of the flow; they converge at the tagging phase and are indistinguishable
from there on:

| | `.roomPlanAssisted` (LiDAR) | `.manualMapping` (non-LiDAR) |
|---|---|---|
| Phase 1 | RoomPlan scan on the shared session | Manual mapping walk: plain ARView + `ARCoachingOverlayView(goal: .tracking)` on the shared session, gated on `worldMappingStatus` |
| Tap raycast | `.estimatedPlane` (mesh-backed — lands on drawer fronts) | `.existingPlaneGeometry` first, then `.estimatedPlane` (plane-backed — needs the surface to have been detected) |
| `capturedRoomData` | Stored (future floor-plan minimap) | `nil` — minimap remains a LiDAR-only feature |
| World map, anchors, save | Identical | Identical |
| Locate mode | Identical | Identical |

Honest degradations on the fallback path: tap precision depends on plane
detection having seen the tapped surface (mitigated by the raycast chain and a
"pan around this spot, then tap again" hint), and tracking is somewhat less
robust in low-texture or dim rooms since there is no depth sensor to lean on.
Relocalization quality is equivalent — it is the same visual-feature mechanism
on both paths.

Side benefit: the manual-mapping path doubles as a future "quick tag" mode for
LiDAR users who want to tag one drawer without a full room scan.

---

## 9. V1.1 additions

**Append-to-room flow.** `ScanAndTagCoordinator` now takes a `Mode` — `.newRoom`
or `.append(RoomModel)`. Append relocalizes into the room's saved map (Locate-style),
lets the user tag additional items on the relocalized session, then calls
`getCurrentWorldMap` again and **replaces** `worldMapData`: the fresh snapshot
contains the original anchors (restored during relocalization) plus the new
ones, so the map stays internally consistent. The room's existing items render
as markers for free — the standard `didAdd` handler doesn't distinguish
restored anchors from fresh ones. One structural constraint: relocalization and
tagging phases share a single `PlacementARViewContainer` identity, otherwise
the restored markers vanish with the discarded ARView.

**Relocalization thumbnail.** A downscaled JPEG of the camera feed is captured
once (first save-worthy frame of tagging) into `RoomModel.referenceImageData`
and shown in the Locate/append "Finding your room" cards as a "point your
camera at this" hint — the cheapest possible way to shorten the hunting phase.

**Guidance haptics + arrival.** `GuidanceHaptics` emits Geiger-counter pulses
whose cadence and weight scale with distance; a success notification plus a
"You're here" banner fire inside 45 cm, with 90 cm exit hysteresis to prevent
flicker. The off-screen chevron is larger and carries an upright live distance.

**Performance split.** `trackingConfiguration(for:)` now distinguishes
`.capture` (planes + LiDAR mesh, for raycasts) from `.locate` (no planes, no
mesh — relocalization is feature-based and doesn't need either), and
environment texturing is off everywhere since all rendering is UnlitMaterial.
Every `ARView` applies `applyGuidanceRenderTuning()` (motion blur, DoF, HDR,
grain, person occlusion, grounding shadows, AR environment lighting all
disabled). Biggest wins: thermals/battery in Locate on Pro, frame pacing on
non-Pro.

**Editing.** Rooms rename via a toolbar alert; assets edit name/notes via
swipe → `@Bindable` sheet. Both are safe by construction: the AR anchor is
keyed by the asset's UUID (`asset:<uuid>`), never by display name.

---

## 10. Non-LiDAR placement accuracy: the reticle system

Tap-to-place is a LiDAR luxury: the mesh gives an instantly correct depth, so
the tap lands where the finger points. Without LiDAR, depth comes from motion
parallax, and a one-shot raycast at tap time commits against an *unrefined*
estimate — errors of 5–15 cm at 2 m are normal, and the user only discovers
them after committing.

The fix is Apple's own Measure-app pattern, wired in for non-LiDAR devices:

- A **tracked raycast** (`ARTrackedRaycast`) runs from screen center; ARKit
  re-delivers refined results every frame as parallax accumulates.
- A **live preview ring** renders at the current result — the user watches it
  settle onto the surface *before* committing, converting invisible error into
  visible feedback.
- A **distance gate** (2.5 m) disables placement at ranges where non-LiDAR
  depth error becomes unreliable, with a "move closer" prompt.
- Tapping the screen on non-LiDAR now just points the user to the crosshair;
  LiDAR devices keep instant tap-to-place.

Realistic expectations, stated honestly: with this system, non-LiDAR placement
error drops from tap-and-pray decimeters to roughly the platform's tracking
floor (~2–4 cm in good light on textured scenes) — sufficient for
"which drawer", not for sub-2-cm pinpointing. Lighting, surface texture, and
user proximity dominate the remaining error budget on both device classes.

**Placement model (revised).** Non-LiDAR devices place via a center-screen
reticle backed by a continuously tracked raycast (`ARTrackedRaycast`): the user
aligns the crosshair, watches the preview ring settle as ARKit refines depth,
and commits with Place Item — gated to ≤ 2.5 m where non-LiDAR depth error is
acceptable. Screen taps for placement are reserved for LiDAR devices, where the
scene mesh makes single taps precise. This supersedes the earlier tap-with-
fallback-chain approach for the fallback path.

---

## 11. V1.2: Spots, photos, and location history

Product plan: see [`ROADMAP.md`](../../ROADMAP.md) (Phase 1).

**Data model.** `Room ──< Spot ──< Item ──< LocationEvent`

| Model | Owns | Notes |
|---|---|---|
| `SpotModel` | The AR anchor (`anchorName`), x/y/z mirror, automatic photo + thumbnail | Tagged once in AR. `anchorName` is stored, not derived, so upgraded spots can keep legacy `asset:<uuid>` anchors |
| `StoredAsset` (item) | Name, notes, own photo + thumbnail, `lastConfirmedDate` | Belongs to a spot. `room` and x/y/z are kept in sync with the spot by `Inventory` |
| `LocationEvent` | Kind (placed/moved), date, snapshot of room/spot names, `spotID` | `spotID` is a plain UUID, not a relationship, so history survives spot deletion |

**Why spots.** AR is needed only to *place a place*. Everything that changes
day to day — adding, moving, removing items — happens in plain SwiftUI screens,
and every move appends a `LocationEvent`. "Where was this originally?" is the
first event, and Locate can guide to that old spot if it still exists.

**Anchor naming.** New anchors are `spot:<uuid>` (`AnchorNaming`). Readers
accept both prefixes forever. In append mode, restored app anchors that no
longer belong to a spot (deleted spots) are removed from the session, so the
next saved map no longer carries them.

**Upgrade path.** `LegacyDataUpgrader` runs at launch: each pre-spot item with
no spot becomes the only item of a new spot pointing at the item's original
`asset:<uuid>` anchor, plus a `placed` history event. Schema changes are
additive (new models, optional attributes, relationships), so SwiftData's
lightweight migration handles the store.

**Photos.** The spot photo is the camera frame at placement time
(`ImageSupport.uprightImage`, orientation-aware for iPad landscape). Item
photos come from the camera or photo library *outside* AR — opening the camera
would interrupt the shared `ARSession`. Every photo is stored as a capped JPEG
(external storage) plus a ~240 px thumbnail used by list rows.

**Search.** Matches item name, notes, spot name, and room name, filtered in
memory (a relationship-spanning `#Predicate` is fragile). Results open the item
screen — photo and "Room › Spot" first; AR guidance is one tap away.
