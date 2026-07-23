//
//  LocateView.swift
//  MicroLocator
//
//  Full-screen Locate experience. The ARView is dumb — all intelligence lives
//  in LocateCoordinator; this file is the SwiftUI shell that renders its
//  published state: relocalization instructions, the distance pill, and the
//  off-screen chevron that rotates toward the target.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

struct LocateView: View {

    let room: RoomModel
    let asset: StoredAsset

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = LocateCoordinator()
    @State private var foundSummary: String? = nil

    var body: some View {
        ZStack {
            LocateARContainer(coordinator: coordinator, room: room, asset: asset)
                .ignoresSafeArea()

            stateOverlay

            // Off-screen chevron: only meaningful while guiding.
            if coordinator.state == .guiding, !coordinator.isTargetOnScreen {
                offScreenChevron
            }

            chrome
        }
        .statusBarHidden()
        .onDisappear { coordinator.stop() }
    }

    // MARK: - State-dependent overlays

    @ViewBuilder
    private var stateOverlay: some View {
        switch coordinator.state {
        case .loadingMap:
            instructionCard(
                icon: "map",
                title: "Loading room…",
                message: "Restoring the saved world map for \(room.name)."
            )

        case .relocalizing:
            instructionCard(
                icon: "camera.viewfinder",
                title: "Finding your room",
                message: referenceThumbnail != nil
                    ? "Point your camera at this area to start."
                    : "Slowly pan your camera around \(room.name), starting near where you began the original scan.",
                thumbnail: referenceThumbnail
            )

        case .searchingAnchor:
            instructionCard(
                icon: "dot.radiowaves.left.and.right",
                title: "Room recognized",
                message: "Pinpointing \(asset.name)…"
            )

        case .guiding:
            guidingHUD

        case .failed(let message):
            instructionCard(
                icon: "exclamationmark.triangle.fill",
                title: "Can't locate right now",
                message: message,
                isError: true
            )
        }
    }

    private var guidingHUD: some View {
        VStack {
            Spacer()
            
            if let summary = foundSummary {
                VStack(spacing: 8) {
                    Text("🎉 Found It! 🎉")
                        .font(.largeTitle.bold())
                    Text(summary)
                        .font(.title3.weight(.medium))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .transition(.scale.combined(with: .opacity))
                .padding(.bottom, 80)
            } else {
                VStack(spacing: 6) {
                    if let data = asset.photoData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, 6)
                    }
                    
                    Text(asset.name)
                        .font(.headline)
                    if !asset.notes.isEmpty {
                        Text(asset.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if coordinator.isArrived {
                        Label("You're here — check this exact spot", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                    } else if let distance = coordinator.distanceText {
                        Label(distance, systemImage: "location.north.line.fill")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.bottom, 44)
                .animation(.easeInOut(duration: 0.2), value: coordinator.isArrived)
            }
        }
    }

    /// A compass-style indicator in the middle of the screen when the target is
    /// outside the viewport (or behind the user). Only the arrow rotates —
    /// the distance stays upright and readable. Angle comes straight from the
    /// coordinator's camera-space math; 0 rad = pointing right.
    private var offScreenChevron: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.yellow)
                .rotationEffect(coordinator.offScreenAngle)
            if let distance = coordinator.distanceText {
                Text(distance)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: Circle())
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: coordinator.offScreenAngle)
    }

    // MARK: - Shared chrome

    private var referenceThumbnail: UIImage? {
        room.referenceImageData.flatMap(UIImage.init(data:))
    }

    private func instructionCard(
        icon: String,
        title: String,
        message: String,
        isError: Bool = false,
        thumbnail: UIImage? = nil
    ) -> some View {
        VStack {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(isError ? .orange : .yellow)
                Text(title)
                    .font(.headline)

                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 190, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 32)
            .padding(.top, 96)

            Spacer()
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    coordinator.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.trailing, 20)
                .padding(.top, 56)
            }
            Spacer()

            if coordinator.state == .guiding && foundSummary == nil {
                Button {
                    let seconds = max(1, Int(coordinator.guidingDuration))
                    let unit = seconds == 1 ? "second" : "seconds"
                    withAnimation(.spring) {
                        foundSummary = "Found in \(seconds) \(unit)!"
                    }
                    coordinator.triggerConfetti()
                    Task {
                        try? await Task.sleep(for: .seconds(3.5))
                        coordinator.stop()
                        dismiss()
                    }
                } label: {
                    Label("Found It", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .padding(.bottom, 130)
            }
        }
    }
}

// MARK: - AR container

private struct LocateARContainer: UIViewRepresentable {

    @ObservedObject var coordinator: LocateCoordinator
    let room: RoomModel
    let asset: StoredAsset

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.applyGuidanceRenderTuning()
        // The coordinator takes over from here: session adoption,
        // automaticallyConfigureSession = false, map load, delegate wiring.
        coordinator.configure(arView: arView, room: room, asset: asset)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}
