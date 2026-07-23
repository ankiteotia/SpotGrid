//
//  RoomCaptureViewRepresentable.swift
//  MicroLocator
//
//  Thin UIViewRepresentable over RoomPlan's RoomCaptureView, with the one
//  deviation from every basic tutorial: the coordinator's shared ARSession is
//  injected via RoomCaptureView(frame:arSession:) (iOS 17), so the scan's
//  world coordinate space outlives the scan itself.
//
//  We drive completion through RoomCaptureSessionDelegate (owned by the
//  coordinator) rather than RoomCaptureViewDelegate — the session delegate is
//  a plain AnyObject protocol and gives us CapturedRoomData directly, whereas
//  the view delegate drags in an NSCoding conformance requirement and a
//  built-in results presentation we don't want (we transition straight into
//  tagging on the still-running session instead).
//

import RoomPlan
import SwiftUI

struct RoomCaptureViewRepresentable: UIViewRepresentable {

    @ObservedObject var coordinator: ScanAndTagCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        // iOS 17: hand RoomPlan OUR session instead of letting it create one.
        let view = RoomCaptureView(frame: .zero, arSession: coordinator.arSession)

        view.captureSession.delegate = coordinator
        coordinator.captureSession = view.captureSession

        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        view.captureSession.run(configuration: configuration)

        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Stateless: the coordinator drives the session lifecycle.
        // Stopping happens via coordinator.finishScanning() →
        // captureSession.stop(pauseARSession: false), so tearing this view
        // down does NOT pause the shared ARSession.
    }
}
