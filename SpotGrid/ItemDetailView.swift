//
//  ItemDetailView.swift
//  SpotGrid
//
//  The answer to "where is my passport?": photo, Room › Spot, and the full
//  location history — including where it was ORIGINALLY kept, with AR guidance
//  to that old spot if someone moved it.
//

import SwiftData
import SwiftUI

struct ItemDetailView: View {

    let item: StoredAsset

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var isMoving = false
    @State private var isConfirmingDelete = false
    @State private var guideTarget: SpotModel?

    var body: some View {
        List {
            if item.photoData != nil {
                Section {
                    PhotoBanner(data: item.photoData)
                        .listRowInsets(EdgeInsets())
                }
            }

            locationSection

            if !item.notes.isEmpty {
                Section("Notes") {
                    Text(item.notes)
                }
            }

            historySection

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Item", systemImage: "trash")
                }
            }
        }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            ItemEditorSheet(mode: .edit(item))
        }
        .sheet(isPresented: $isMoving) {
            MoveItemSheet(item: item)
        }
        .fullScreenCover(item: $guideTarget) { spot in
            if let room = spot.room {
                LocateView(room: room, spot: spot, item: item)
            }
        }
        .confirmationDialog(
            "Delete \(item.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Item", role: .destructive) {
                DeferredDeletion.run(after: dismiss) {
                    Inventory.delete(item, in: modelContext)
                }
            }
        } message: {
            Text("Its location history is deleted too.")
        }
    }

    // MARK: - Where it is

    private var locationSection: some View {
        Section {
            if let spot = item.spot {
                NavigationLink {
                    SpotDetailView(spot: spot)
                } label: {
                    HStack(spacing: 12) {
                        PhotoThumbnail(
                            data: spot.thumbnailData,
                            size: 64,
                            placeholderSystemImage: "mappin.and.ellipse"
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(spot.name)
                                .font(.headline)
                            Text(spot.room?.name ?? "")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button {
                    guideTarget = spot
                } label: {
                    Label("Guide Me in AR", systemImage: "location.viewfinder")
                }
                .disabled(spot.room?.worldMapData == nil)
            } else {
                Text("This item isn't in a spot yet.")
                    .foregroundStyle(.secondary)
            }

            Button {
                isMoving = true
            } label: {
                Label("Move to Another Spot", systemImage: "arrow.left.arrow.right")
            }

            Button {
                Inventory.confirmStillThere(item, in: modelContext)
            } label: {
                Label("It's Still Here", systemImage: "checkmark.circle")
            }
        } header: {
            Text("Where It Is")
        } footer: {
            Text(confirmationText)
        }
    }

    private var confirmationText: String {
        if let date = item.lastConfirmedDate {
            return "Last confirmed \(date.formatted(.relative(presentation: .named)))."
        }
        return "Added \(item.dateAdded.formatted(date: .abbreviated, time: .omitted)). Not confirmed since."
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        let events = item.sortedHistory
        if !events.isEmpty {
            Section {
                // Newest first; the last row is the original location.
                ForEach(Array(events.enumerated().reversed()), id: \.element.id) { index, event in
                    HistoryRow(
                        event: event,
                        isOriginal: index == 0 && events.count > 1,
                        isCurrent: index == events.count - 1,
                        resolvedSpot: Inventory.spot(withID: event.spotID, in: modelContext),
                        onGuide: { guideTarget = $0 }
                    )
                }
            } header: {
                Text("History")
            } footer: {
                if item.hasMoved {
                    Text("If it's not where it is now, check its original spot — use Guide to get there.")
                }
            }
        }
    }
}

// MARK: - History row

private struct HistoryRow: View {
    let event: LocationEvent
    let isOriginal: Bool
    let isCurrent: Bool
    /// The spot this entry points to, if it still exists.
    let resolvedSpot: SpotModel?
    let onGuide: (SpotModel) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind == .placed ? "mappin.circle.fill" : "arrow.right.circle.fill")
                .font(.title3)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.kind == .placed ? "Placed in" : "Moved to")
                    .font(.subheadline.weight(.medium))
                Text(locationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(event.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if isOriginal { HistoryBadge(text: "Original") }
                    if isCurrent { HistoryBadge(text: "Now") }
                }
            }

            Spacer(minLength: 8)

            // A bordered button keeps the tap target to the button itself.
            if !isCurrent, let spot = resolvedSpot, spot.room?.worldMapData != nil {
                Button("Guide") { onGuide(spot) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// Current names when the spot still exists; the names it had at the time
    /// (snapshotted in the event) when it has been deleted.
    private var locationText: String {
        if let resolvedSpot { return resolvedSpot.locationText }
        return "\(event.roomName) › \(event.spotName) (spot deleted)"
    }
}

private struct HistoryBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}
