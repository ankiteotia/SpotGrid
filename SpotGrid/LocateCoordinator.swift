//
//  LocateCoordinator.swift
//  MicroLocator
//
//  Drives Locate mode:
//
//    loadingMap   → unarchive the room's ARWorldMap (background; maps are big)
//    relocalizing → session runs with initialWorldMap; user pans until ARKit
//                   recognizes the space (tracking → .normal)
//    searching    → waiting for the restored named anchor via didAdd
//    guiding      → arrow mounted; per-frame distance + on/off-screen guidance
//
//  Fallback: if the named anchor doesn't resurface within a few seconds of
//  relocalization (e.g. map saved by an older build), the arrow is placed at
//  the SwiftData-mirrored x/y/z — valid because relocalization has already
//  re-established the original world origin.
//

// ARWorldMap / ARFrame are not Sendable; each crossing is a one-shot hand-off.
@preconcurrency import ARKit

import Combine
import RealityKit
import SwiftUI

@MainActor
final class LocateCoordinator: NSObject, ObservableObject {

    enum State: Equatable {
        case loadingMap
        case relocalizing
        case searchingAnchor
        case guiding
        case failed(String)
    }

    // MARK: - Published guidance state

    @Published private(set) var state: State = .loadingMap
    @Published private(set) var distanceText: String?
    @Published private(set) var isTargetOnScreen = false
    @Published private(set) var offScreenAngle: Angle = .zero
    @Published private(set) var isArrived = false

    // MARK: - Internals

    let arSession = ARSession()
    private weak var arView: ARView?
    private let persistence = ARPersistenceManager()

    private var targetAnchorName = ""
    private var storedFallbackPosition = SIMD3<Float>.zero

    private var guidanceAnchor: AnchorEntity?
    private var arrowEntity: Entity?
    private var updateSubscription: (any Cancellable)?
    private var elapsed: TimeInterval = 0
    private var fallbackScheduled = false
    private var guidingStartTime: Date?

    private let arrowHoverHeight: Float = 0.28

    private let haptics = GuidanceHaptics()
    /// Arrival hysteresis: enter at 45 cm, exit at 90 cm — so the banner and
    /// success haptic can't flicker when the user hovers at the boundary.
    private let arrivalEnterDistance: Float = 0.45
    private let arrivalExitDistance: Float = 0.90

    // MARK: - Lifecycle

    func configure(arView: ARView, room: RoomModel, asset: StoredAsset) {
        self.arView = arView
        targetAnchorName = asset.anchorName
        storedFallbackPosition = asset.worldPosition

        arView.automaticallyConfigureSession = false
        arView.session = arSession
        arSession.delegate = self   // main queue by default
        haptics.prepare()

        // One per-frame hook drives all animation + guidance math.
        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            // Fires on the main thread as part of the render loop.
            MainActor.assumeIsolated {
                self?.tick(deltaTime: event.deltaTime)
            }
        }

        guard let mapData = room.worldMapData else {
            state = .failed(ARPersistenceError.missingWorldMap.localizedDescription)
            return
        }
        Task { await loadAndRun(mapData: mapData) }
    }

    func stop() {
        updateSubscription?.cancel()
        updateSubscription = nil
        arSession.pause()
    }

    // MARK: - Map loading & relocalization

    private func loadAndRun(mapData: Data) async {
        do {
            // Unarchiving tens of MB is CPU-bound — keep it off the main actor
            // so the camera feed appears without a hitch.
            let worldMap = try await Task.detached(priority: .userInitiated) {
                [persistence] in
                try persistence.unarchive(mapData)
            }.value

            let config = persistence.trackingConfiguration(for: .locate, initialWorldMap: worldMap)
            // Reset into the RESTORED map's coordinate system. The map's
            // embedded anchors (our items) are re-delivered via didAdd once
            // ARKit relocalizes.
            arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
            state = .relocalizing
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// If the named anchor never resurfaces, fall back to mirrored coordinates.
    private func scheduleFallbackPlacement() {
        guard !fallbackScheduled else { return }
        fallbackScheduled = true

        Task {
            try? await Task.sleep(for: .seconds(10))
            guard state == .searchingAnchor, guidanceAnchor == nil else { return }
            mountGuidance(on: AnchorEntity(world: storedFallbackPosition))
        }
    }

    // MARK: - Guidance mounting

    private func mountGuidance(on anchor: AnchorEntity) {
        guard guidanceAnchor == nil, let arView else { return }

        let arrow = EntityFactory.guidanceArrow()
        arrow.position = [0, arrowHoverHeight, 0]
        anchor.addChild(arrow)
        anchor.addChild(EntityFactory.targetRing())

        arView.scene.addAnchor(anchor)
        guidanceAnchor = anchor
        arrowEntity = arrow
        state = .guiding
        guidingStartTime = Date()
    }

    var guidingDuration: TimeInterval {
        guard let start = guidingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    func triggerConfetti() {
        guard let anchor = guidanceAnchor else { return }
        let burst = EntityFactory.confetti()
        burst.position = [0, 0.2, 0]
        anchor.addChild(burst)
    }

    // MARK: - Per-frame guidance

    private func tick(deltaTime: TimeInterval) {
        elapsed += deltaTime
        guard state == .guiding, let arView, let guidanceAnchor else { return }

        // Bob + spin — cheap sinusoidal animation, no AnimationResource plumbing.
        if let arrowEntity {
            arrowEntity.position.y = arrowHoverHeight + 0.045 * Float(sin(elapsed * 2.4))
            arrowEntity.orientation = simd_quatf(angle: Float(elapsed * 1.6), axis: [0, 1, 0])
        }

        let target = guidanceAnchor.position(relativeTo: nil)
        let cameraTransform = arView.cameraTransform

        // Distance readout.
        let distance = simd_distance(cameraTransform.translation, target)
        distanceText = distance < 1
            ? String(format: "%.0f cm", distance * 100)
            : String(format: "%.1f m", distance)

        // Geiger-counter haptics: cadence tightens as the user closes in.
        haptics.update(distance: distance, deltaTime: deltaTime)

        // Arrival with hysteresis (enter 45 cm / exit 90 cm).
        if !isArrived, distance < arrivalEnterDistance {
            isArrived = true
            haptics.arrival()
        } else if isArrived, distance > arrivalExitDistance {
            isArrived = false
        }

        updateScreenGuidance(target: target, cameraMatrix: cameraTransform.matrix, in: arView)
    }

    /// Decides whether the target is on-screen; if not, computes the rotation
    /// for a screen-space chevron pointing toward it.
    private func updateScreenGuidance(
        target: SIMD3<Float>,
        cameraMatrix: simd_float4x4,
        in arView: ARView
    ) {
        // Target in camera space: +x right, +y up, -z forward.
        let local = cameraMatrix.inverse * SIMD4<Float>(target, 1)
        let isInFront = local.z < 0

        if isInFront,
           let projected = arView.project(target),
           arView.bounds.insetBy(dx: 24, dy: 24).contains(projected) {
            isTargetOnScreen = true
            return
        }

        isTargetOnScreen = false

        // Screen space: x right, y DOWN, rotationEffect positive = clockwise.
        // So screen direction = (camX, -camY); if behind the camera, the whole
        // direction flips.
        let dirX = isInFront ? local.x : -local.x
        let dirY = isInFront ? -local.y : local.y
        offScreenAngle = .radians(Double(atan2(dirY, dirX)))
    }
}

// MARK: - ARSessionDelegate

extension LocateCoordinator: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let trackingState = camera.trackingState   // value type; safe to carry
        MainActor.assumeIsolated {
            switch trackingState {
            case .normal:
                // Relocalized into the saved map — anchors are (about to be) live.
                if state == .relocalizing {
                    state = .searchingAnchor
                    scheduleFallbackPlacement()
                }
            case .limited(.relocalizing):
                if state == .searchingAnchor { state = .relocalizing }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for anchor in anchors where anchor.name == targetAnchorName {
                // The restored anchor from the world map — the precise, ARKit-
                // refined position. Preferred over the SwiftData fallback.
                mountGuidance(on: AnchorEntity(anchor: anchor))
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { @MainActor in
            state = .failed(error.localizedDescription)
        }
    }
}
