//
//  SpotModel.swift
//  SpotGrid
//
//  A physical place tagged once in AR — "Almirah drawer 2", "Top shelf",
//  "Box 4". A spot owns the AR anchor; items live *in* spots and can be added,
//  moved, or removed later without opening AR at all.
//
//  Room ──< Spot ──< Item ──< LocationEvent
//

import Foundation
import SwiftData
import simd

@Model
final class SpotModel {

    @Attribute(.unique) var id: UUID
    var name: String
    var dateCreated: Date

    /// Name of the ARAnchor inside the room's world map. Stored rather than
    /// derived from `id`: spots created by `LegacyDataUpgrader` keep pointing at
    /// the `asset:<uuid>` anchors that older builds wrote into saved maps.
    var anchorName: String

    // Mirror of the anchor's position, used as the fallback placement when the
    // anchor doesn't resurface after relocalization. SwiftData can't store SIMD.
    var xCoordinate: Float
    var yCoordinate: Float
    var zCoordinate: Float

    /// Camera frame captured the moment the spot was tagged — the "before"
    /// photo shown in search results, item screens, and on arrival in Locate.
    @Attribute(.externalStorage) var photoData: Data?

    /// Small JPEG for list rows, so lists never load the full photo.
    var thumbnailData: Data?

    var room: RoomModel?

    /// Deleting a spot deletes the items in it (the UI asks first).
    @Relationship(deleteRule: .cascade, inverse: \StoredAsset.spot)
    var items: [StoredAsset] = []

    init(
        id: UUID = UUID(),
        name: String,
        dateCreated: Date = .now,
        anchorName: String? = nil,
        position: SIMD3<Float>,
        photo: PhotoPair? = nil
    ) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.anchorName = anchorName ?? AnchorNaming.spotAnchorName(for: id)
        self.xCoordinate = position.x
        self.yCoordinate = position.y
        self.zCoordinate = position.z
        self.photoData = photo?.photo
        self.thumbnailData = photo?.thumbnail
    }

    var worldPosition: SIMD3<Float> {
        SIMD3<Float>(xCoordinate, yCoordinate, zCoordinate)
    }

    var sortedItems: [StoredAsset] {
        items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Bedroom › Almirah drawer 2"
    var locationText: String {
        guard let roomName = room?.name else { return name }
        return "\(roomName) › \(name)"
    }
}
