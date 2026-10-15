//
//  MoveItemSheet.swift
//  SpotGrid
//
//  Pick the spot an item now lives in — any spot in any room. No AR needed;
//  the move is recorded in the item's history so its original location is
//  never lost.
//

import SwiftData
import SwiftUI

struct MoveItemSheet: View {

    let item: StoredAsset

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \RoomModel.name) private var rooms: [RoomModel]

    private var roomsWithSpots: [RoomModel] {
        rooms.filter { !$0.spots.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(roomsWithSpots) { room in
                    Section(room.name) {
                        ForEach(room.sortedSpots) { spot in
                            spotButton(spot)
                        }
                    }
                }

                if !roomsWithSpots.isEmpty {
                    Section {
                    } footer: {
                        Text("Moving it somewhere new? Tag that place first with Add Spots on the room screen.")
                    }
                }
            }
            .navigationTitle("Move \(item.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if roomsWithSpots.isEmpty {
                    ContentUnavailableView(
                        "No Spots Yet",
                        systemImage: "mappin.slash",
                        description: Text("Tag a spot in a room first.")
                    )
                }
            }
        }
    }

    private func spotButton(_ spot: SpotModel) -> some View {
        let isCurrent = spot.id == item.spot?.id
        return Button {
            Inventory.move(item, to: spot, in: modelContext)
            dismiss()
        } label: {
            HStack {
                SpotRow(spot: spot)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Current spot")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }
}
