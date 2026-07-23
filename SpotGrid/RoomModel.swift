//
//  RoomModel.swift
//  MicroLocator
//
//  One scanned physical room. Owns the serialized ARWorldMap that makes every
//  StoredAsset's coordinates meaningful — coordinates are only valid *inside*
//  the world map they were captured in.
//

import Foundation
import SwiftData

@Model
final class RoomModel {

    @Attribute(.unique) var id: UUID
    var name: String
    var scannedDate: Date

    /// The ARWorldMap, archived via NSKeyedArchiver and LZFSE-compressed by
    /// `ARPersistenceManager`. World maps commonly weigh 10–60 MB, so
    /// `.externalStorage` keeps the blob in a sidecar file instead of bloating
    /// the SQLite store (SwiftData manages the file's lifecycle for us).
    @Attribute(.externalStorage) var worldMapData: Data?

    /// Optional: the parametric RoomPlan output. `CapturedRoom` is Codable, so we
    /// keep it around cheaply — it's the seed for a future 2D floor-plan minimap
    /// showing item dots, without needing to re-scan.
    @Attribute(.externalStorage) var capturedRoomData: Data?

    /// One-time JPEG of what the camera saw early in tagging — shown during
    /// relocalization in Locate/append modes as a "stand here and point at
    /// this" visual hint, which dramatically shortens the hunting phase.
    @Attribute(.externalStorage) var referenceImageData: Data?

    /// Deleting a room deletes its items. `inverse` is declared on this side only;
    /// SwiftData maintains `StoredAsset.room` automatically.
    @Relationship(deleteRule: .cascade, inverse: \StoredAsset.room)
    var assets: [StoredAsset] = []

    init(id: UUID = UUID(), name: String, scannedDate: Date = .now) {
        self.id = id
        self.name = name
        self.scannedDate = scannedDate
    }
}
