//
//  RoomListView.swift
//  MicroLocator
//
//  Landing page: all scanned rooms + a global search bar over every tagged
//  item. Search flips the list into asset results (dynamic @Query with a
//  #Predicate built at init — the SwiftData-idiomatic way to do live-filtered
//  queries). Selecting a result jumps straight into Locate mode.
//

import SwiftData
import SwiftUI

struct RoomListView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RoomModel.scannedDate, order: .reverse) private var rooms: [RoomModel]

    @State private var searchText = ""
    @State private var isPresentingScan = false
    @State private var assetToLocate: StoredAsset?

    var body: some View {
        NavigationStack {
            Group {
                if !DeviceCapabilities.supportsWorldTracking {
                    unsupportedDevice
                } else if searchText.isEmpty {
                    roomsList
                } else {
                    AssetSearchResultsView(searchText: searchText) { asset in
                        assetToLocate = asset
                    }
                }
            }
            .navigationTitle("Spatial Organizer")
            .searchable(text: $searchText, prompt: "Find an item (e.g. Passport)")
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
            .fullScreenCover(item: $assetToLocate) { asset in
                // An asset without a room can't be located — the guard lives in
                // the search view, so force of habit only: fall back gracefully.
                if let room = asset.room {
                    LocateView(room: room, asset: asset)
                }
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
                description: Text("Scan your first room, then tap drawers and shelves to tag where things live.")
            )
        } else {
            List {
                ForEach(rooms) { room in
                    NavigationLink {
                        RoomDetailView(room: room) { asset in
                            assetToLocate = asset
                        }
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
                Label("\(room.assets.count) items", systemImage: "mappin.and.ellipse")
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

struct RoomDetailView: View {

    let room: RoomModel
    let onLocate: (StoredAsset) -> Void

    @State private var isAppendingItems = false
    @State private var isRenamingRoom = false
    @State private var renameDraft = ""
    @State private var assetToEdit: StoredAsset?

    private var sortedAssets: [StoredAsset] {
        room.assets.sorted { $0.dateAdded > $1.dateAdded }
    }

    var body: some View {
        List {
            Section {
                ForEach(sortedAssets) { asset in
                    Button {
                        onLocate(asset)
                    } label: {
                        assetRow(asset)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            assetToEdit = asset
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } header: {
                Text("Tagged Items")
            } footer: {
                Text("Tap an item to be guided to it in AR. Swipe to edit its name or notes.")
            }
        }
        // room is a @Model (Observable) — the title updates live on rename.
        .navigationTitle(room.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isAppendingItems = true
                } label: {
                    Label("Add Items", systemImage: "plus.viewfinder")
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
        .fullScreenCover(isPresented: $isAppendingItems) {
            // Relocalize into this room's saved map, tag new items, re-save.
            ScanFlowView(mode: .append(room))
        }
        .sheet(item: $assetToEdit) { asset in
            EditAssetSheet(asset: asset)
                .presentationDetents([.height(320)])
        }
        .overlay {
            if room.assets.isEmpty {
                ContentUnavailableView(
                    "Nothing Tagged",
                    systemImage: "mappin.slash",
                    description: Text("This room was saved without any tagged items. Use Add Items to tag some.")
                )
            }
        }
    }

    private func assetRow(_ asset: StoredAsset) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name)
                    .font(.body.weight(.medium))
                if !asset.notes.isEmpty {
                    Text(asset.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "location.viewfinder")
                .foregroundStyle(.tint)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Edit asset sheet

/// Direct @Bindable editing of the SwiftData model — changes autosave live.
/// Safe by design: the AR anchor is keyed by the asset's UUID
/// ("asset:<uuid>"), never by its display name, so renaming an item can never
/// disturb its saved spatial location.
struct EditAssetSheet: View {

    @Bindable var asset: StoredAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $asset.name)
                TextField("Notes", text: $asset.notes, axis: .vertical)
                    .lineLimit(2...4)
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(asset.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Global search results

/// Dynamic @Query pattern: the predicate is built in init from the live search
/// text, so SwiftData does the filtering (localizedStandardContains is
/// diacritic/case-insensitive — the right behavior for "where's my passport").
struct AssetSearchResultsView: View {

    @Query private var results: [StoredAsset]
    private let onLocate: (StoredAsset) -> Void

    init(searchText: String, onLocate: @escaping (StoredAsset) -> Void) {
        self.onLocate = onLocate
        let predicate = #Predicate<StoredAsset> {
            $0.name.localizedStandardContains(searchText)
            || $0.notes.localizedStandardContains(searchText)
        }
        _results = Query(filter: predicate, sort: \StoredAsset.dateAdded, order: .reverse)
    }

    var body: some View {
        List(results) { asset in
            Button {
                guard asset.room != nil else { return }
                onLocate(asset)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.name)
                            .font(.body.weight(.medium))
                        Text(asset.room?.name ?? "Unknown room")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.turn.up.right")
                        .foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search
            }
        }
    }
}
