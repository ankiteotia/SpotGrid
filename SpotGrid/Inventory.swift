//
//  Inventory.swift
//  SpotGrid
//
//  Every item mutation goes through here so the invariants hold everywhere:
//    - item.room always equals item.spot?.room
//    - item's x/y/z mirror its spot's position
//    - every placement and move appends a LocationEvent (history is never lost)
//

import Foundation
import SwiftData
import os

enum Inventory {

    private static let logger = Logger(subsystem: "com.SpotGrid", category: "Inventory")

    // MARK: - Items

    /// Adds a new item to a spot and saves.
    @discardableResult
    static func addItem(
        named name: String,
        notes: String = "",
        photo: PhotoPair? = nil,
        to spot: SpotModel,
        in context: ModelContext
    ) -> StoredAsset {
        let item = makeItem(named: name, notes: notes, photo: photo, in: spot, context: context)
        save(context)
        return item
    }

    /// Inserts an item without saving — for callers that save a larger batch
    /// themselves (e.g. the capture flow saving a whole room).
    @discardableResult
    static func makeItem(
        named name: String,
        notes: String = "",
        photo: PhotoPair? = nil,
        in spot: SpotModel,
        context: ModelContext
    ) -> StoredAsset {
        let item = StoredAsset(name: name, notes: notes, position: spot.worldPosition)
        context.insert(item)
        item.photoData = photo?.photo
        item.thumbnailData = photo?.thumbnail
        item.spot = spot
        item.room = spot.room
        recordEvent(.placed, item: item, spot: spot, context: context)
        return item
    }

    /// Moves an item to another spot (any room) and records the move.
    static func move(_ item: StoredAsset, to spot: SpotModel, in context: ModelContext) {
        guard item.spot?.id != spot.id else { return }
        item.spot = spot
        item.room = spot.room
        item.worldPosition = spot.worldPosition
        // The user just put it there, so the location is confirmed as of now.
        item.lastConfirmedDate = .now
        recordEvent(.moved, item: item, spot: spot, context: context)
        save(context)
    }

    static func confirmStillThere(_ item: StoredAsset, in context: ModelContext) {
        item.lastConfirmedDate = .now
        save(context)
    }

    static func setPhoto(_ photo: PhotoPair?, for item: StoredAsset, in context: ModelContext) {
        item.photoData = photo?.photo
        item.thumbnailData = photo?.thumbnail
        save(context)
    }

    static func delete(_ item: StoredAsset, in context: ModelContext) {
        context.delete(item)
        save(context)
    }

    // MARK: - Spots

    /// Deletes a spot and (by cascade) the items in it. Its anchor stays in the
    /// room's world map until the next "Add Spots" session prunes it.
    static func delete(_ spot: SpotModel, in context: ModelContext) {
        context.delete(spot)
        save(context)
    }

    /// Looks up a spot by id — used to resolve history entries, which store a
    /// spot id rather than a relationship so they survive the spot's deletion.
    static func spot(withID id: UUID?, in context: ModelContext) -> SpotModel? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<SpotModel>(predicate: #Predicate<SpotModel> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    // MARK: - Internals

    private static func recordEvent(
        _ kind: LocationEventKind,
        item: StoredAsset,
        spot: SpotModel,
        context: ModelContext
    ) {
        let event = LocationEvent(kind: kind, spot: spot)
        context.insert(event)
        event.item = item
    }

    private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            // The change stays in the context and autosave retries it.
            logger.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
