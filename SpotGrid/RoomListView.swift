//
//  RoomListView.swift
//  MicroLocator
//
//  Landing page: all scanned rooms + a global search bar over every item.
//  Search flips the list into item results showing photo + "Room › Spot" —
//  the answer is on screen before AR is even needed. AR guidance is one tap
//  away on the item screen.
//

import SwiftData
import SwiftUI

struct RoomListView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RoomModel.scannedDate, order: .reverse) private var rooms: [RoomModel]

    @State private var searchText = ""
    @State private var isPresentingScan = false

    var body: some View {
        NavigationStack {
            Group {
                if !DeviceCapabilities.supportsWorldTracking {
                    unsupportedDevice
                } else if searchText.isEmpty {
                    roomsList
                } else {
                    ItemSearchResultsView(searchText: searchText)
                }
            }
            .navigationTitle("SpotGrid")
            .searchable(text: $searchText, prompt: "Find an item, spot, or room")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingScan = true
                    } label: {
                        Label("Scan Room", systemImage: "plus.viewfinder")
                    }
                    .disabled(!DeviceCapabilities.supportsWorldTracking)
                }
            }
            .fullScreenCover(isPresented: $isPresentingScan) {
                ScanFlowView()
            }
        }
    }

    // MARK: - Rooms

    @ViewBuilder
    private var roomsList: some View {
        if rooms.isEmpty {
            ContentUnavailableView(
                "No Rooms Yet",
                systemImage: "square.split.bottomrightquarter",
                description: Text("Scan your first room, then tag drawers, shelves, and boxes as spots.")
            )
        } else {
            List {
                ForEach(rooms) { room in
                    NavigationLink {
                        RoomDetailView(room: room)
                    } label: {
                        roomRow(room)
                    }
                }
                .onDelete(perform: deleteRooms)
            }
        }
    }

    private func roomRow(_ room: RoomModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(room.name)
                .font(.headline)
            HStack(spacing: 12) {
                Label("\(room.spots.count) spots", systemImage: "mappin.and.ellipse")
                Label("\(room.assets.count) items", systemImage: "shippingbox")
                Label(room.scannedDate.formatted(date: .abbreviated, time: .omitted),
                      systemImage: "calendar")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func deleteRooms(at offsets: IndexSet) {
        // Cascade rule on RoomModel.assets removes the items too.
        for index in offsets {
            modelContext.delete(rooms[index])
        }
    }

    private var unsupportedDevice: some View {
        // Effectively unreachable on iOS 17 (device floor is A12 / iPhone XS,
        // all ARKit world-tracking capable) — kept as a defensive gate.
        ContentUnavailableView(
            "AR Not Supported",
            systemImage: "camera.metering.unknown",
            description: Text("This device doesn't support ARKit world tracking, which the app needs to remember where your items are.")
        )
    }
}

// MARK: - Room detail

/// A room's spots. Each spot opens to its items; managing items never needs AR.
struct RoomDetailView: View {

    let room: RoomModel

    @Environment(\.modelContext) private var modelContext

    @State private var isAppendingSpots = false
    @State private var isRenamingRoom = false
    @State private var renameDraft = ""
    @State private var spotPendingDeletion: SpotModel?

    var body: some View {
        List {
            Section {
                ForEach(room.sortedSpots) { spot in
                    NavigationLink {
                        SpotDetailView(spot: spot)
                    } label: {
                        SpotRow(spot: spot)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Not role: .destructive — that role removes the row
                        // before the confirmation dialog has been answered.
                        Button {
                            spotPendingDeletion = spot
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            } header: {
                Text("Spots")
            } footer: {
                Text("A spot is a place tagged in AR — a drawer, shelf, or box. Open one to add, move, or remove items without AR.")
            }
        }
        // room is a @Model (Observable) — the title updates live on rename.
        .navigationTitle(room.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isAppendingSpots = true
                } label: {
                    Label("Add Spots", systemImage: "plus.viewfinder")
                }

                Menu {
                    Button {
                        renameDraft = room.name
                        isRenamingRoom = true
                    } label: {
                        Label("Rename Room", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Room", isPresented: $isRenamingRoom) {
            TextField("Room name", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { room.name = trimmed }   // SwiftData autosaves
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this spot?",
            isPresented: Binding(
                get: { spotPendingDeletion != nil },
                set: { if !$0 { spotPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: spotPendingDeletion
        ) { spot in
            Button(SpotDeletion.buttonTitle(for: spot), role: .destructive) {
                Inventory.delete(spot, in: modelContext)
            }
        } message: { _ in
            Text(SpotDeletion.message)
        }
        .fullScreenCover(isPresented: $isAppendingSpots) {
            // Relocalize into this room's saved map, tag new spots, re-save.
            ScanFlowView(mode: .append(room))
        }
        .overlay {
            if room.spots.isEmpty {
                ContentUnavailableView(
                    "No Spots Yet",
                    systemImage: "mappin.slash",
                    description: Text("Use Add Spots to tag drawers, shelves, and boxes in this room.")
                )
            }
        }
    }
}

// MARK: - Global search results

/// Matches item name, notes, spot name, and room name. Filtering happens in
/// memory: the relationship-spanning predicate this needs is fragile in
/// SwiftData, and a household inventory is small.
struct ItemSearchResultsView: View {

    let searchText: String

    @Query(sort: \StoredAsset.name) private var allItems: [StoredAsset]

    private var results: [StoredAsset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return allItems.filter { $0.matches(query) }
    }

    var body: some View {
        List(results) { item in
            NavigationLink {
                ItemDetailView(item: item)
            } label: {
                ItemRow(item: item, showsLocation: true)
            }
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}
