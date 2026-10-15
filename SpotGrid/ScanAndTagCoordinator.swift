//
//  ScanAndTagCoordinator.swift
//  MicroLocator
//
//  The heart of the capture flow, now serving TWO modes:
//
//  .newRoom — the original flow. One ARSession shared across:
//      1. RoomPlan scanning (LiDAR) or a manual mapping walk (non-LiDAR)
//      2. Spot tagging (RealityKit ARView on the same session) — each spot
//         gets a `spot:<uuid>` anchor, an automatic photo, and optional items
//      3. World map capture (getCurrentWorldMap → archive → SwiftData)
//
//  .append(room) — add spots to an EXISTING room:
//      1. Relocalize into the room's saved ARWorldMap (like Locate mode)
//      2. Restored anchors reappear via didAdd → existing spots render as
//         markers; anchors of deleted spots are pruned
//      3. Tag new spots on the relocalized session
//      4. getCurrentWorldMap AGAIN — the fresh map contains old + new anchors
//         together — and REPLACE the room's worldMapData with it
//
//  In both modes the session never resets between phases, so every anchor
//  lives in one consistent world coordinate space that gets serialized whole.
//

// CapturedRoomData / ARFrame / ARWorldMap are not Sendable; crossings below
// are one-shot hand-offs into the main actor. See ARCHITECTURE.md §5.
@preconcurrency import ARKit
@preconcurrency import RoomPlan

import Combine
import CoreVideo
import Foundation
import RealityKit
import SwiftData
import SwiftUI
import UIKit

@MainActor
final class ScanAndTagCoordinator: NSObject, ObservableObject {

    // MARK: - Types

    /// What this capture session is for.
    enum Mode {
        /// Fresh room: scan (LiDAR) or mapping walk (non-LiDAR), then tag.
        case newRoom
        /// Existing room: relocalize into its saved map, tag additional items,
        /// then re-save the map with old + new anchors riding together.
        case append(RoomModel)
    }

    enum Phase: Equatable {
        /// LiDAR path: RoomPlan structural scan.
        case scanning
        /// Non-LiDAR path: manual feature-mapping walk before tagging.
        case mapping
        /// Append mode: finding the saved room before tagging can begin.
        case relocalizingExisting
        case processingScan
        case tagging
        case saving
        case saved
        case failed(String)
    }

    /// A confirmed spot, held in memory until the room is saved as a whole.
    struct DraftSpot: Identifiable, Equatable {
        let id: UUID
        var name: String
        var itemNames: [String]
        let transform: simd_float4x4
        let photo: PhotoPair?

        var position: SIMD3<Float> {
            SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }
    }

    /// A raycast hit awaiting the user's spot name in the tag sheet. The photo
    /// is taken at placement time, while the camera still points at the spot.
    struct PendingPlacement: Identifiable {
        let id = UUID()
        let transform: simd_float4x4
        let photo: PhotoPair?
    }

    /// Live state of the non-LiDAR crosshair placement system.
    enum ReticleStatus: Equatable {
        case inactive          // LiDAR device, or not in tagging phase
        case searching         // no surface locked under the crosshair yet
        case ready(Float)      // surface locked; distance in meters
        case tooFar(Float)     // locked but beyond reliable placement range
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase
    @Published private(set) var draftSpots: [DraftSpot] = []
    @Published var pendingPlacement: PendingPlacement?
    @Published private(set) var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    @Published var transientHint: String?
    @Published var saveError: String?
    @Published private(set) var reticle: ReticleStatus = .inactive

    // MARK: - Spatial plumbing

    let mode: Mode

    /// The single shared session. Created here, injected into RoomCaptureView
    /// (new-room LiDAR path) or run directly, then adopted by the tagging
    /// ARView. Never recreated mid-flow.
    let arSession = ARSession()

    /// Set by RoomCaptureViewRepresentable so we can stop the scan on demand.
    weak var captureSession: RoomCaptureSession?

    /// Set when a placement/mapping container comes on screen.
    private weak var arView: ARView?

    private let persistence = ARPersistenceManager()
    private(set) var capturedRoom: CapturedRoom?

    private var appendSessionStarted = false
    private var referenceSnapshotJPEG: Data?

    /// App anchors that should render as markers: the room's current spots
    /// (append mode) plus every spot tagged this session. Restored anchors NOT
    /// in this set belong to deleted spots and are removed from the session,
    /// so the next saved map no longer carries them.
    private var liveAnchorNames: Set<String> = []

    // Reticle placement (non-LiDAR): a tracked raycast from screen center that
    // ARKit continuously refines, with a live preview entity. Tap-to-place is
    // reserved for LiDAR devices where the mesh makes taps precise.
    private var trackedRaycast: ARTrackedRaycast?
    private var reticlePreviewAnchor: AnchorEntity?
    private var lastReticleTransform: simd_float4x4?
    /// Non-LiDAR depth error grows roughly quadratically with distance — past
    /// this range, placements get unreliably sloppy, so we ask for proximity.
    private let maxReticlePlacementDistance: Float = 2.5

    private var usesReticlePlacement: Bool {
        !DeviceCapabilities.supportsSceneReconstruction
    }

    var isAppending: Bool {
        if case .append = mode { return true }
        return false
    }

    // MARK: - Init

    init(mode: Mode = .newRoom) {
        self.mode = mode
        switch mode {
        case .newRoom:
            // LiDAR devices get the RoomPlan-assisted flow; everyone else
            // starts with a manual mapping walk on the same shared session.
            phase = DeviceCapabilities.captureStrategy == .roomPlanAssisted ? .scanning : .mapping
        case .append:
            phase = .relocalizingExisting
        }
        super.init()
        if case .append(let room) = mode {
            liveAnchorNames = Set(room.spots.map(\.anchorName))
        }
    }

    // MARK: - Phase 1 (non-LiDAR fallback): manual mapping

    /// Fallback entry point: no RoomPlan, so world tracking starts here. The
    /// user walks the room while ARCoachingOverlayView and the mapping-status
    /// chip guide them; the same shared session then carries into tagging.
    func beginManualMapping(in arView: ARView) {
        self.arView = arView
        arSession.delegate = self
        arSession.run(persistence.trackingConfiguration(for: .capture))
    }

    func startTaggingAfterMapping() {
        guard phase == .mapping, mappingStatus.isSufficientForSaving else { return }
        phase = .tagging
        transientHint = Self.taggingHint
    }

    // MARK: - Phase 1 → 2: finish scanning (LiDAR path)

    func finishScanning() {
        guard phase == .scanning else { return }
        phase = .processingScan
        // The load-bearing line of the whole app: end RoomPlan's UI, keep the
        // underlying ARSession tracking so tagging inherits the world origin.
        captureSession?.stop(pauseARSession: false)
        // → RoomCaptureSessionDelegate.captureSession(_:didEndWith:) fires next.
    }

    // MARK: - Placement session (tagging for both modes)

    /// Called by PlacementARViewContainer once its ARView exists.
    ///
    /// .newRoom:  the session is already tracking (RoomPlan handed it over, or
    ///            the mapping walk started it) — re-run our capture config with
    ///            NO reset options so the world origin is preserved.
    /// .append:   the session hasn't run yet — load the room's saved map and
    ///            run WITH reset options to relocalize into it. Old anchors
    ///            return via didAdd; tagging unlocks once tracking is .normal.
    func beginPlacementSession(in arView: ARView) {
        self.arView = arView
        arSession.delegate = self   // main queue by default (delegateQueue == nil)

        switch mode {
        case .newRoom:
            // CRITICALLY: empty options — no .resetTracking, no
            // .removeExistingAnchors — preserving the established world origin.
            arSession.run(persistence.trackingConfiguration(for: .capture))
            if phase == .tagging {
                transientHint = Self.taggingHint
            }

        case .append(let room):
            guard !appendSessionStarted else { return }   // container re-created; session already live
            appendSessionStarted = true
            guard let mapData = room.worldMapData else {
                phase = .failed(ARPersistenceError.missingWorldMap.localizedDescription)
                return
            }
            Task { await startAppendRelocalization(mapData: mapData) }
        }
    }

    private func startAppendRelocalization(mapData: Data) async {
        do {
            // Unarchiving tens of MB is CPU-bound — keep it off the main actor.
            let worldMap = try await Task.detached(priority: .userInitiated) {
                [persistence] in
                try persistence.unarchive(mapData)
            }.value

            // Reset into the restored map's coordinate system; its embedded
            // anchors (the room's existing items) are re-delivered via didAdd.
            arSession.run(
                persistence.trackingConfiguration(for: .capture, initialWorldMap: worldMap),
                options: [.resetTracking, .removeExistingAnchors]
            )
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Tap → raycast → pending placement (LiDAR path)

    func handleTap(at point: CGPoint) {
        guard phase == .tagging, let arView else { return }

        // Non-LiDAR: taps commit against an unrefined depth estimate and land
        // centimeters-to-decimeters off — the crosshair flow replaces them.
        if usesReticlePlacement {
            transientHint = "Use the crosshair — line it up with the exact spot, then tap Place Spot"
            return
        }

        // LiDAR: .estimatedPlane raycasts against the scene-reconstruction
        // mesh, landing precisely on drawer fronts and shelf edges.
        guard let result = arView
            .raycast(from: point, allowing: .estimatedPlane, alignment: .any)
            .first
        else {
            transientHint = "No surface there — aim at a drawer, shelf, or wall"
            return
        }

        pendingPlacement = PendingPlacement(
            transform: result.worldTransform,
            photo: captureSpotPhoto()
        )
    }

    // MARK: - Reticle placement (non-LiDAR path)

    /// Lazily started from `session(_:didUpdate:)` once the tagging ARView has
    /// real bounds. A tracked raycast is the accuracy upgrade here: unlike a
    /// one-shot raycast, ARKit keeps refining its result every frame as
    /// parallax improves its depth estimate — the user literally watches the
    /// preview ring settle onto the surface before committing.
    private func startReticleIfNeeded() {
        guard usesReticlePlacement,
              phase == .tagging,
              trackedRaycast == nil,
              let arView,
              arView.bounds.width > 0
        else { return }

        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let query = arView.makeRaycastQuery(
            from: center,
            allowing: .estimatedPlane,
            alignment: .any
        ) else { return }

        let preview = AnchorEntity(world: SIMD3<Float>.zero)
        preview.addChild(EntityFactory.reticlePreview())
        preview.isEnabled = false
        arView.scene.addAnchor(preview)
        reticlePreviewAnchor = preview
        reticle = .searching

        trackedRaycast = arSession.trackedRaycast(query) { [weak self] results in
            // Delivered on the session delegate queue — main by default.
            MainActor.assumeIsolated {
                self?.reticleDidUpdate(results)
            }
        }
    }

    private func reticleDidUpdate(_ results: [ARRaycastResult]) {
        guard phase == .tagging else { return }

        guard let result = results.first, let arView else {
            lastReticleTransform = nil
            reticlePreviewAnchor?.isEnabled = false
            reticle = .searching
            return
        }

        lastReticleTransform = result.worldTransform
        reticlePreviewAnchor?.isEnabled = true
        reticlePreviewAnchor?.transform = Transform(matrix: result.worldTransform)

        let position = SIMD3<Float>(
            result.worldTransform.columns.3.x,
            result.worldTransform.columns.3.y,
            result.worldTransform.columns.3.z
        )
        let distance = simd_distance(arView.cameraTransform.translation, position)
        reticle = distance > maxReticlePlacementDistance ? .tooFar(distance) : .ready(distance)
    }

    /// The non-LiDAR "Place Spot" action: commit the latest refined transform.
    func placeAtReticle() {
        guard case .ready = reticle, let transform = lastReticleTransform else { return }
        pendingPlacement = PendingPlacement(transform: transform, photo: captureSpotPhoto())
    }

    private func stopReticle() {
        trackedRaycast?.stopTracking()
        trackedRaycast = nil
        reticlePreviewAnchor?.removeFromParent()
        reticlePreviewAnchor = nil
        lastReticleTransform = nil
        reticle = .inactive
    }

    /// User confirmed the tag sheet: mint the named anchor. The name embeds the
    /// spot UUID, so the anchor inside the world map and the SwiftData row are
    /// permanently linked — and renaming the spot later never touches it.
    func confirmPendingSpot(name: String, itemNames: [String]) {
        guard let pending = pendingPlacement else { return }
        pendingPlacement = nil

        let spotID = UUID()
        draftSpots.append(
            DraftSpot(
                id: spotID,
                name: name,
                itemNames: itemNames,
                transform: pending.transform,
                photo: pending.photo
            )
        )

        let anchorName = AnchorNaming.spotAnchorName(for: spotID)
        liveAnchorNames.insert(anchorName)
        arSession.add(anchor: ARAnchor(name: anchorName, transform: pending.transform))
        // → session(_:didAdd:) renders the visual marker.
    }

    func removeDraft(_ draft: DraftSpot) {
        draftSpots.removeAll { $0.id == draft.id }
        let name = AnchorNaming.spotAnchorName(for: draft.id)
        liveAnchorNames.remove(name)
        if let anchor = arSession.currentFrame?.anchors.first(where: { $0.name == name }) {
            arSession.remove(anchor: anchor)
        }
    }

    // MARK: - Save (new room)

    func saveRoom(named roomName: String, in context: ModelContext) async {
        guard case .newRoom = mode, phase == .tagging else { return }
        stopReticle()
        phase = .saving

        do {
            let mapData = try await captureArchivedMap()

            let room = RoomModel(name: roomName)
            room.worldMapData = mapData
            room.referenceImageData = referenceSnapshotJPEG
            if let capturedRoom {
                room.capturedRoomData = try? JSONEncoder().encode(capturedRoom)
            }
            context.insert(room)
            insertDraftSpots(into: room, context: context)

            try context.save()
            arSession.pause()
            phase = .saved
        } catch {
            saveError = error.localizedDescription
            phase = .tagging
        }
    }

    // MARK: - Save (append to existing room)

    func saveAppendedSpots(in context: ModelContext) async {
        guard case .append(let room) = mode, phase == .tagging else { return }
        stopReticle()
        phase = .saving

        do {
            // The fresh snapshot contains the ORIGINAL anchors (restored during
            // relocalization) plus every anchor added this session — so simply
            // replacing worldMapData keeps everything consistent.
            room.worldMapData = try await captureArchivedMap()

            // Keep the original reference snapshot if one exists — the
            // relocalization hint should stay stable across append sessions.
            if room.referenceImageData == nil {
                room.referenceImageData = referenceSnapshotJPEG
            }
            insertDraftSpots(into: room, context: context)

            try context.save()
            arSession.pause()
            phase = .saved
        } catch {
            saveError = error.localizedDescription
            phase = .tagging
        }
    }

    /// Turns this session's drafts into spots (same UUID the anchor name
    /// embeds) with their items. The caller saves.
    private func insertDraftSpots(into room: RoomModel, context: ModelContext) {
        for draft in draftSpots {
            let spot = SpotModel(
                id: draft.id,
                name: draft.name,
                position: draft.position,
                photo: draft.photo
            )
            context.insert(spot)
            spot.room = room

            for itemName in draft.itemNames {
                Inventory.makeItem(named: itemName, in: spot, context: context)
            }
        }
    }

    private func captureArchivedMap() async throws -> Data {
        // 1. Snapshot the world map — every named item anchor rides inside it.
        let worldMap = try await persistence.captureWorldMap(from: arSession)
        // 2. Serialize (NSKeyedArchiver + LZFSE). One-off CPU cost at flow end.
        return try persistence.archive(worldMap)
    }

    func cancelFlow() {
        stopReticle()
        arSession.pause()
    }

    // MARK: - Photos

    private static let taggingHint = "Tap a drawer, shelf, or box to tag it as a spot"

    private var interfaceOrientation: UIInterfaceOrientation {
        arView?.window?.windowScene?.interfaceOrientation ?? .portrait
    }

    /// The spot's "before" photo: the current camera frame at placement time.
    /// Runs on the main actor (~30–50 ms, once per placement) right as the tag
    /// sheet slides over the camera, so the hitch is masked. Move it off-main
    /// if profiling on non-Pro devices shows otherwise.
    private func captureSpotPhoto() -> PhotoPair? {
        guard let pixelBuffer = arSession.currentFrame?.capturedImage,
              let image = ImageSupport.uprightImage(
                  from: pixelBuffer,
                  interfaceOrientation: interfaceOrientation,
                  scale: 0.5
              )
        else { return nil }
        return ImageSupport.photoPair(from: image, maxDimension: 1280)
    }

    /// Downscaled JPEG of the camera feed, captured once when tracking first
    /// becomes save-worthy during tagging. Shown later as the "point your
    /// camera at this area" relocalization hint.
    private func referenceSnapshot(from pixelBuffer: CVPixelBuffer) -> Data? {
        guard let image = ImageSupport.uprightImage(
            from: pixelBuffer,
            interfaceOrientation: interfaceOrientation,
            scale: 0.3
        ) else { return nil }
        return ImageSupport.jpegData(from: image, maxDimension: 640, compressionQuality: 0.6)
    }
}

// MARK: - RoomCaptureSessionDelegate

extension ScanAndTagCoordinator: RoomCaptureSessionDelegate {

    /// RoomPlan makes no queue guarantee for its delegate → hop to MainActor
    /// with a Task rather than assumeIsolated.
    nonisolated func captureSession(
        _ session: RoomCaptureSession,
        didEndWith data: CapturedRoomData,
        error: (any Error)?
    ) {
        Task { @MainActor in
            if let error {
                self.phase = .failed("Scan failed: \(error.localizedDescription)")
                return
            }
            do {
                // Build the parametric model off the raw capture. Not required
                // for anchor persistence — kept for the future floor-plan view.
                let builder = RoomBuilder(options: [.beautifyObjects])
                self.capturedRoom = try await builder.capturedRoom(from: data)
            } catch {
                // Non-fatal: tagging + world map persistence don't depend on it.
                self.capturedRoom = nil
            }
            self.phase = .tagging
        }
    }
}

// MARK: - ARSessionDelegate

extension ScanAndTagCoordinator: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Read values out; never retain ARFrame beyond this callback.
        let status = frame.worldMappingStatus
        // Safe: ARSession delivers on the main queue when delegateQueue == nil.
        MainActor.assumeIsolated {
            if status != mappingStatus { mappingStatus = status }

            // Reticle needs the ARView to have laid out — cheap guarded check.
            startReticleIfNeeded()

            // One-time reference snapshot, taken as soon as tagging-phase
            // tracking is trustworthy. ~30 ms of CI work exactly once.
            if referenceSnapshotJPEG == nil,
               phase == .tagging,
               status.isSufficientForSaving {
                referenceSnapshotJPEG = referenceSnapshot(from: frame.capturedImage)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            guard let arView else { return }
            // Covers BOTH freshly tapped anchors and — in append mode — the
            // room's original anchors restored during relocalization, which is
            // how existing spots show up as markers for free.
            var staleAnchors: [ARAnchor] = []
            for anchor in anchors where AnchorNaming.isAppAnchor(anchor.name) {
                guard let name = anchor.name, liveAnchorNames.contains(name) else {
                    // A spot deleted since the map was saved — prune it.
                    staleAnchors.append(anchor)
                    continue
                }
                let anchorEntity = AnchorEntity(anchor: anchor)
                anchorEntity.addChild(EntityFactory.itemMarker())
                arView.scene.addAnchor(anchorEntity)
            }
            staleAnchors.forEach { arSession.remove(anchor: $0) }
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let trackingState = camera.trackingState   // value type; safe to carry
        MainActor.assumeIsolated {
            // Append mode: tagging unlocks the moment relocalization succeeds.
            guard phase == .relocalizingExisting, case .normal = trackingState else { return }
            phase = .tagging
            transientHint = "Room recognized — existing spots are shown in teal. Tap to add new ones"
        }
    }
}
