//
//  ScanFlowView.swift
//  MicroLocator
//
//  Full-screen capture flow for BOTH modes:
//    .newRoom  — scan/map → tag spots → name the room → save
//    .append   — relocalize into an existing room → tag new spots → save
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
            TagSpotSheet(
                photo: placement.photo,
                onConfirm: { spotName, itemNames in
                    coordinator.confirmPendingSpot(name: spotName, itemNames: itemNames)
                },
                onCancel: { coordinator.pendingPlacement = nil }
            )
            .presentationDetents([.medium, .large])
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
                ProgressView(coordinator.isAppending ? "Saving spots & updated map…" : "Saving room & world map…")
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
                Label("Place Spot Here", systemImage: "mappin.and.ellipse")
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
            Label(spotCountText, systemImage: "mappin.and.ellipse")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button {
                if coordinator.isAppending {
                    Task { await coordinator.saveAppendedSpots(in: modelContext) }
                } else {
                    isPresentingSaveSheet = true
                }
            } label: {
                Text(coordinator.isAppending ? "Save Spots" : "Save Room")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!coordinator.mappingStatus.isSufficientForSaving || coordinator.draftSpots.isEmpty)
        }
    }

    private var spotCountText: String {
        let count = coordinator.draftSpots.count
        let noun = count == 1 ? "spot" : "spots"
        return coordinator.isAppending ? "\(count) new \(noun)" : "\(count) \(noun)"
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

// MARK: - Tag spot sheet

/// Names the spot just placed and, optionally, lists what's in it. Items can
/// be added, moved, or removed later without AR, so this stays quick.
struct TagSpotSheet: View {
    let photo: PhotoPair?
    let onConfirm: (_ spotName: String, _ itemNames: [String]) -> Void
    let onCancel: () -> Void

    @State private var spotName = ""
    @State private var itemNames: [String] = [""]
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case spot
        case item(Int)
    }

    private var trimmedSpotName: String {
        spotName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let data = photo?.photo, let image = UIImage(data: data) {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("This photo is saved with the spot.")
                    }
                }

                Section {
                    TextField("Spot name (e.g. Almirah drawer 2)", text: $spotName)
                        .focused($focusedField, equals: .spot)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .item(0) }
                } header: {
                    Text("Spot")
                } footer: {
                    Text("A place you keep things — a drawer, shelf, box, or cupboard.")
                }

                Section {
                    ForEach(itemNames.indices, id: \.self) { index in
                        TextField("Item (e.g. Passport)", text: $itemNames[index])
                            .focused($focusedField, equals: .item(index))
                            .submitLabel(.next)
                            .onSubmit { advance(from: index) }
                    }
                    Button {
                        addItemField()
                    } label: {
                        Label("Add Another Item", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Items Here (Optional)")
                } footer: {
                    Text("You can add, move, or remove items later without AR.")
                }
            }
            .navigationTitle("Tag This Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Place Spot") {
                        let items = itemNames
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onConfirm(trimmedSpotName, items)
                    }
                    .disabled(trimmedSpotName.isEmpty)
                }
            }
            .onAppear { focusedField = .spot }
        }
    }

    private func advance(from index: Int) {
        let isLast = index == itemNames.count - 1
        let isEmpty = itemNames[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isLast {
            if !isEmpty { addItemField() }
        } else {
            focusedField = .item(index + 1)
        }
    }

    private func addItemField() {
        itemNames.append("")
        focusedField = .item(itemNames.count - 1)
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
