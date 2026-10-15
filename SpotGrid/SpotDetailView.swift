//
//  SpotDetailView.swift
//  SpotGrid
//
//  One spot: its photo, the items in it, and AR guidance to it. Adding,
//  removing, and opening items here never touches AR.
//

import SwiftData
import SwiftUI

struct SpotDetailView: View {

    let spot: SpotModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isAddingItem = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var isConfirmingDelete = false
    @State private var isGuiding = false

    private var canGuide: Bool { spot.room?.worldMapData != nil }

    var body: some View {
        List {
            Section {
                if spot.photoData != nil {
                    PhotoBanner(data: spot.photoData)
                        .listRowInsets(EdgeInsets())
                }
                LabeledContent("Room", value: spot.room?.name ?? "—")
                LabeledContent(
                    "Tagged",
                    value: spot.dateCreated.formatted(date: .abbreviated, time: .omitted)
                )
                Button {
                    isGuiding = true
                } label: {
                    Label("Guide Me Here in AR", systemImage: "location.viewfinder")
                }
                .disabled(!canGuide)
            }

            Section {
                ForEach(spot.sortedItems) { item in
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        ItemRow(item: item, showsLocation: false)
                    }
                }
                .onDelete(perform: deleteItems)

                Button {
                    isAddingItem = true
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
            } header: {
                Text("Items Here")
            } footer: {
                Text("Adding, moving, or removing items doesn't need AR.")
            }
        }
        .navigationTitle(spot.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameDraft = spot.name
                        isRenaming = true
                    } label: {
                        Label("Rename Spot", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Spot", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Spot", isPresented: $isRenaming) {
            TextField("Spot name", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                // The anchor is keyed by UUID, so renaming never moves the spot.
                if !trimmed.isEmpty { spot.name = trimmed }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this spot?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(SpotDeletion.buttonTitle(for: spot), role: .destructive) {
                DeferredDeletion.run(after: dismiss) {
                    Inventory.delete(spot, in: modelContext)
                }
            }
        } message: {
            Text(SpotDeletion.message)
        }
        .sheet(isPresented: $isAddingItem) {
            ItemEditorSheet(mode: .add(spot))
        }
        .fullScreenCover(isPresented: $isGuiding) {
            if let room = spot.room {
                LocateView(room: room, spot: spot, item: nil)
            }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let items = spot.sortedItems
        for index in offsets {
            Inventory.delete(items[index], in: modelContext)
        }
    }
}
