//
//  PlacementARViewContainer.swift
//  MicroLocator
//
//  The tagging-phase ARView. It ADOPTS the coordinator's shared ARSession —
//  the same one RoomPlan just used — so tap-placed anchors land in the scan's
//  coordinate space.
//
//  automaticallyConfigureSession = false is non-negotiable here: left at its
//  default, ARView runs a brand-new configuration the moment it enters a
//  window, resetting the world origin and silently invalidating everything.
//

import ARKit
import RealityKit
import SwiftUI

struct PlacementARViewContainer: UIViewRepresentable {

    @ObservedObject var coordinator: ScanAndTagCoordinator

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        arView.automaticallyConfigureSession = false   // do not touch our world
        arView.applyGuidanceRenderTuning()
        arView.session = coordinator.arSession
        coordinator.beginPlacementSession(in: arView)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(TapProxy.handleTap(_:))
        )
        arView.addGestureRecognizer(tap)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> TapProxy {
        TapProxy(owner: coordinator)
    }

    /// UIKit target-action needs an NSObject; this proxy just forwards the tap
    /// location to the real coordinator.
    @MainActor
    final class TapProxy: NSObject {
        private let owner: ScanAndTagCoordinator

        init(owner: ScanAndTagCoordinator) {
            self.owner = owner
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            owner.handleTap(at: gesture.location(in: view))
        }
    }
}
