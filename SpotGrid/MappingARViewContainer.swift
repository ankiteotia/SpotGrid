//
//  MappingARViewContainer.swift
//  MicroLocator
//
//  Non-LiDAR replacement for the RoomPlan phase: a plain ARView on the shared
//  session, with ARCoachingOverlayView doing the "move your phone" dance while
//  ARKit builds the feature map. Once worldMappingStatus is good, ScanFlowView
//  advances to tagging — same session, same world origin, same everything
//  downstream.
//
//  Design note: taps are deliberately NOT wired here. Letting users place
//  anchors before the map is trustworthy produces anchors that drift the
//  moment ARKit re-optimizes — better to gate placement behind the status chip.
//

import ARKit
import RealityKit
import SwiftUI

struct MappingARViewContainer: UIViewRepresentable {

    @ObservedObject var coordinator: ScanAndTagCoordinator

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        arView.automaticallyConfigureSession = false
        arView.applyGuidanceRenderTuning()
        arView.session = coordinator.arSession
        coordinator.beginManualMapping(in: arView)

        let coaching = ARCoachingOverlayView()
        coaching.session = coordinator.arSession
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: arView.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
        ])

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
