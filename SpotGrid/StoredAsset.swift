//
//  StoredAsset.swift
//  MicroLocator
//
//  A physical item ("Passport") that lives in a spot ("Almirah drawer 2").
//  Since V1.2 the AR anchor belongs to the spot, not the item — so items can be
//  added, moved, and deleted without AR, and every move is recorded in
//  `history`.
//
//  The x/y/z columns mirror the current spot's position. They predate spots:
//  older builds anchored each item directly (`asset:<uuid>`), and
//  `LegacyDataUpgrader` uses these columns to turn such items into spots.
//

import Foundation
import SwiftData
import simd

@Model
final class StoredAsset {

    @Attribute(.unique) var id: UUID
    var name: String
    var notes: String
    var dateAdded: Date

    // SwiftData can't persist SIMD types directly — store scalar columns.
    var xCoordinate: Float
    var yCoordinate: Float
    var zCoordinate: Float

    /// Kept in sync with `spot?.room` (see `Inventory`). Also the link legacy
    /// items had before spots existed.
    var room: RoomModel?

    /// Where the item is now. Nil only for legacy rows not yet upgraded.
    var spot: SpotModel?

    /// The user's own photo of the item (camera or library).
    @Attribute(.externalStorage) var photoData: Data?

    /// Small JPEG for list rows.
    var thumbnailData: Data?

    /// Last time the user confirmed the item is really where the app says.
    var lastConfirmedDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \LocationEvent.item)
    var history: [LocationEvent] = []

    init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        dateAdded: Date = .now,
        position: SIMD3<Float>
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.dateAdded = dateAdded
        self.xCoordinate = position.x
        self.yCoordinate = position.y
        self.zCoordinate = position.z
    }

    /// Convenience view over the scalar columns. Transient — not persisted itself.
    var worldPosition: SIMD3<Float> {
        get { SIMD3<Float>(xCoordinate, yCoordinate, zCoordinate) }
        set {
            xCoordinate = newValue.x
            yCoordinate = newValue.y
            zCoordinate = newValue.z
        }
    }

    /// Oldest first. The first entry is the item's original location.
    var sortedHistory: [LocationEvent] {
        history.sorted { $0.date < $1.date }
    }

    var originalEvent: LocationEvent? { sortedHistory.first }

    var hasMoved: Bool { history.count > 1 }

    /// "Bedroom › Almirah drawer 2"
    var locationText: String {
        spot?.locationText ?? room?.name ?? "No location"
    }

    /// Row thumbnail: the item's own photo, else the photo of its spot.
    var displayThumbnail: Data? {
        thumbnailData ?? spot?.thumbnailData
    }

    /// Search across everything a person might remember: the item, its notes,
    /// the spot, or the room.
    func matches(_ query: String) -> Bool {
        let fields = [name, notes, spot?.name ?? "", spot?.room?.name ?? room?.name ?? ""]
        return fields.contains { $0.localizedStandardContains(query) }
    }
}
