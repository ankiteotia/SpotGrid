# SpotGrid — notes for Claude

- **What it is:** offline iOS/iPadOS app that remembers where things are kept
  (Room → Spot → Items) and guides the user back with photos, text and AR.
- **Plan:** read [`ROADMAP.md`](ROADMAP.md) first and keep its checkboxes up to date.
  Design details: [`SpotGrid/Helpers/ARCHITECTURE.md`](SpotGrid/Helpers/ARCHITECTURE.md).
- **Platform:** minimum iOS 17.6 (intentional). iPhone and iPad are both first-class;
  every screen must work in iPad landscape. LiDAR is optional (two capture paths).
- **Build settings to respect:** Swift 5 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`, approachable concurrency, `MemberImportVisibility` (import every module whose
  members a file uses). The `SpotGrid/` folder is a synchronized group: new `.swift` files
  are picked up automatically — never hand-edit `project.pbxproj` to add files.
- **No network, no cloud, no analytics.** Newer-than-17.6 APIs go behind `#available`.
- **Cloud sessions can't build:** there is no Xcode on Linux. Write code carefully, and
  tell the user what to verify on a real device (AR does not run in the simulator).
- **AR invariants:** one shared `ARSession` per capture flow; `automaticallyConfigureSession
  = false`; never reset tracking between scan and tagging. Anchor names are the bridge to
  SwiftData — see `AnchorNaming` (`spot:<uuid>` for spots, legacy `asset:<uuid>` must keep
  working).
