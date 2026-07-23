//
//  ScanFlowView.swift
//  MicroLocator
//
//  Full-screen capture flow for BOTH modes:
//    .newRoom  — scan/map → tag → name the room → save
//    .append   — relocalize into an existing room → tag new items → save
//
//  One structural rule matters here: in append mode, the relocalization and
//  tagging phases MUST share the same PlacementARViewContainer instance. The
//  room's restored anchors render into that ARView's scene during
//  relocalization — if SwiftUI swapped the container between phases, those
//  markers would silently vanish with the old ARView.
//

import ARKit
import SwiftData
import SwiftUI
import UIKit
import PhotosUI

struct ScanFlowView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var coordinator: ScanAndTagCoordinator
    @State private var isPresentingSaveSheet = false

    init(mode: ScanAndTagCoordinator.Mode = .newRoom) {
        _coordinator = StateObject(wrappedValue: ScanAndTagCoordinator(mode: mode))
    }

    var body: some View {
        ZStack {
            switch coordinator.phase {
            case .scanning:
                scanningLayer
            case .mapping:
                mappingLayer
            case .processingScan:
                processingLayer
            case .relocalizingExisting, .tagging, .saving:
                // One branch → one container identity across all three phases.
                taggingLayer
            case .saved:
                Color.black // momentary — onChange dismisses
            case .failed(let message):
                failureLayer(message)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .interactiveDismissDisabled()
        .sheet(item: $coordinator.pendingPlacement) { placement in
            TagItemSheet(
                onConfirm: { name, notes, iconName, photoData in
                    coordinator.confirmPendingAsset(name: name, notes: notes, iconName: iconName, photoData: photoData)
                },
                onCancel: { coordinator.pendingPlacement = nil }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isPresentingSaveSheet) {
            SaveRoomSheet { roomName in
                isPresentingSaveSheet = false
                Task { await coordinator.saveRoom(named: roomName, in: modelContext) }
            }
            .presentationDetents([.height(220)])
        }
        .alert(
            "Couldn't Save Yet",
            isPresented: Binding(
                get: { coordinator.saveError != nil },
                set: { if !$0 { coordinator.saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.saveError ?? "")
        }
        .onChange(of: coordinator.phase) { _, newPhase in
            if newPhase == .saved { dismiss() }
        }
        .onDisappear {
            coordinator.cancelFlow()
        }
    }

    // MARK: - Scanning (LiDAR / RoomPlan)

    private var scanningLayer: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureViewRepresentable(coordinator: coordinator)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Walk slowly around the room, keeping walls and furniture in view.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .foregroundStyle(.white)

                Button {
                    coordinator.finishScanning()
                } label: {
                    Text("Finish Scan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 40)

            closeButton
        }
    }

    // MARK: - Mapping (non-LiDAR fallback)

    private var mappingLayer: some View {
        ZStack {
            MappingARViewContainer(coordinator: coordinator)
                .ignoresSafeArea()

            VStack {
                mappingStatusChip
                    .padding(.top, 60)

                Spacer()

                VStack(spacing: 12) {
                    Text("Walk the room slowly and point the camera at furniture, walls, and the spots you'll tag. The button unlocks once the room is mapped.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)

                    Button {
                        coordinator.startTaggingAfterMapping()
                    } label: {
                        Text("Start Tagging")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.mappingStatus.isSufficientForSaving)
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 40)
            }

            closeButton
        }
    }

    // MARK: - Processing

    private var processingLayer: some View {
        ZStack {
            Color.black
            ProgressView("Building room model…")
                .tint(.white)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Relocalize + Tagging (shared container)

    private var taggingLayer: some View {
        ZStack {
            PlacementARViewContainer(coordinator: coordinator)
                .ignoresSafeArea()

            // Non-LiDAR crosshair — dead center, colored by reticle state.
            if coordinator.phase == .tagging, coordinator.reticle != .inactive {
                reticleCrosshair
            }

            VStack {
                if coordinator.phase == .relocalizingExisting {
                    appendRelocalizeCard
                        .padding(.top, 96)
                } else {
                    mappingStatusChip
                        .padding(.top, 60)

                    if let hint = coordinator.transientHint {
                        Text(hint)
                            .font(.footnote)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 8)
                    }
                }

                Spacer()

                if coordinator.phase != .relocalizingExisting {
                    if coordinator.reticle != .inactive {
                        reticlePlaceControls
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                    }

                    bottomBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 36)
                }
            }

            if coordinator.phase == .saving {
                Color.black.opacity(0.55).ignoresSafeArea()
                ProgressView(coordinator.isAppending ? "Saving items & updated map…" : "Saving room & world map…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            closeButton
        }
    }

    // MARK: - Reticle UI (non-LiDAR)

    private var reticleColor: Color {
        switch coordinator.reticle {
        case .ready:   return .green
        case .tooFar:  return .orange
        default:       return .yellow
        }
    }

    private var reticleCrosshair: some View {
        ZStack {
            Circle()
                .stroke(reticleColor, lineWidth: 2)
                .frame(width: 34, height: 34)
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(reticleColor)
        }
        .shadow(radius: 2)
        .allowsHitTesting(false)
    }

    private var reticlePlaceControls: some View {
        VStack(spacing: 10) {
            Group {
                switch coordinator.reticle {
                case .searching:
                    Text("Point the crosshair at a surface and hold steady")
                case .tooFar(let distance):
                    Text(String(format: "Too far (%.1f m) — move closer for an accurate tag", distance))
                case .ready(let distance):
                    Text(String(format: "Locked · %.1f m — let the ring settle, then place", distance))
                case .inactive:
                    EmptyView()
                }
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())

            Button {
                coordinator.placeAtReticle()
            } label: {
                Label("Place Item Here", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled({
                if case .ready = coordinator.reticle { return false }
                return true
            }())
        }
    }

    /// Append mode's "finding your room" card, with the reference snapshot if
    /// the room has one — the fastest possible relocalization hint.
    private var appendRelocalizeCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.title)
                .foregroundStyle(.yellow)
            Text("Finding your room")
                .font(.headline)

            if case .append(let room) = coordinator.mode,
               let data = room.referenceImageData,
               let thumbnail = UIImage(data: data) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 190, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Point your camera at this area to start.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Slowly pan around the room, starting near where the original scan began.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 32)
    }

    private var mappingStatusChip: some View {
        Label(
            coordinator.mappingStatus.userLabel,
            systemImage: coordinator.mappingStatus.isSufficientForSaving
                ? "checkmark.circle.fill"
                : "arrow.triangle.2.circlepath"
        )
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(
            coordinator.mappingStatus.isSufficientForSaving ? .green : .orange
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Label("\(coordinator.draftAssets.count) \(coordinator.isAppending ? "new" : "tagged")",
                  systemImage: "mappin.and.ellipse")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button {
                if coordinator.isAppending {
                    Task { await coordinator.saveAppendedItems(in: modelContext) }
                } else {
                    isPresentingSaveSheet = true
                }
            } label: {
                Text(coordinator.isAppending ? "Save Items" : "Save Room")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!coordinator.mappingStatus.isSufficientForSaving || coordinator.draftAssets.isEmpty)
        }
    }

    // MARK: - Failure / chrome

    private func failureLayer(_ message: String) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    coordinator.cancelFlow()
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
        }
    }
}

// MARK: - Tag item sheet

struct TagItemSheet: View {
    let onConfirm: (_ name: String, _ notes: String, _ iconName: String, _ photoData: Data?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var notes = ""
    @State private var iconName = "mappin.and.ellipse"
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    
    @FocusState private var nameFocused: Bool

    let iconChoices = ["mappin.and.ellipse", "key.fill", "doc.text.fill", "lanyardcard.fill", "laptopcomputer", "tshirt.fill", "glasses", "pills.fill", "bag.fill", "creditcard.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item name (e.g. Passport)", text: $name)
                        .focused($nameFocused)
                    TextField("Notes (e.g. in Drawer 3, under the files)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                
                Section("Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(iconChoices, id: \.self) { icon in
                                Image(systemName: icon)
                                    .font(.title2)
                                    .foregroundStyle(iconName == icon ? .white : .primary)
                                    .frame(width: 44, height: 44)
                                    .background(iconName == icon ? Color.accentColor : Color(uiColor: .systemFill))
                                    .clipShape(Circle())
                                    .onTapGesture {
                                        iconName = icon
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }
                
                Section("Photo (Optional)") {
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        if let photoData, let uiImage = UIImage(data: photoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Label("Add a Photo", systemImage: "camera.viewfinder")
                        }
                    }
                    .onChange(of: photoItem) { _, newItem in
                        Task {
                            guard let data = try? await newItem?.loadTransferable(type: Data.self),
                                  let uiImage = UIImage(data: data) else { return }
                            let thumbnail = uiImage.preparingThumbnail(of: CGSize(width: 800, height: 800))
                            photoData = (thumbnail ?? uiImage).jpegData(compressionQuality: 0.7)
                        }
                    }
                    if photoData != nil {
                        Button("Remove Photo", role: .destructive) {
                            photoItem = nil
                            photoData = nil
                        }
                    }
                }
            }
            .navigationTitle("Tag This Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Place Tag") {
                        onConfirm(name.trimmingCharacters(in: .whitespaces), notes, iconName, photoData)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
    }
}

// MARK: - Save room sheet

struct SaveRoomSheet: View {
    let onSave: (_ roomName: String) -> Void
    @State private var roomName = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Room name (e.g. Bedroom)", text: $roomName)
            }
            .navigationTitle("Save Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(roomName.trimmingCharacters(in: .whitespaces))
                    }
                    .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
