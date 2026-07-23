//
//  StoredAsset.swift
//  MicroLocator
//
//  A physically tagged item ("Passport in Drawer 3"). The x/y/z here is a
//  *mirror* of the named ARAnchor that lives inside the room's ARWorldMap:
//
//    - The anchor inside the map is the spatial source of truth (ARKit refines
//      anchor transforms during relocalization; raw floats can't).
//    - These columns exist so the item is searchable/queryable via SwiftData,
//      and as a fallback placement if the anchor fails to resurface.
//
//  The bridge between the two worlds is `AnchorNaming`:
//  ARAnchor.name == "asset:" + id.uuidString
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

    @Attribute(.externalStorage) var photoData: Data?
    var iconName: String = "mappin.and.ellipse"

    // SwiftData can't persist SIMD types directly — store scalar columns.
    var xCoordinate: Float
    var yCoordinate: Float
    var zCoordinate: Float

    var room: RoomModel?

    init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        iconName: String = "mappin.and.ellipse",
        photoData: Data? = nil,
        dateAdded: Date = .now,
        position: SIMD3<Float>
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.iconName = iconName
        self.photoData = photoData
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

    /// The name of the ARAnchor that represents this asset inside the world map.
    var anchorName: String { AnchorNaming.name(for: id) }
}
