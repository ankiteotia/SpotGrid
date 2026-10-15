//
//  LegacyDataUpgrader.swift
//  SpotGrid
//
//  One-time, idempotent upgrade from the pre-spot data model, where every item
//  owned its own AR anchor (`asset:<uuid>`). Each such item becomes the only
//  item of a new spot that points at the very same anchor — so rooms saved by
//  older builds keep locating correctly without rewriting their world maps.
//
//  Safe to run on every launch: it only touches items that have no spot.
//

import Foundation
import SwiftData
import os

enum LegacyDataUpgrader {

    static func upgradeIfNeeded(in context: ModelContext) {
        // Filter in memory: nil checks on to-one relationships inside
        // #Predicate have been unreliable on early iOS 17 releases.
        guard let items = try? context.fetch(FetchDescriptor<StoredAsset>()) else { return }
        let legacyItems = items.filter { $0.spot == nil && $0.room != nil }
        guard !legacyItems.isEmpty else { return }

        for item in legacyItems {
            guard let room = item.room else { continue }

            let spot = SpotModel(
                name: item.name,
                dateCreated: item.dateAdded,
                anchorName: AnchorNaming.legacyAssetAnchorName(for: item.id),
                position: item.worldPosition
            )
            context.insert(spot)
            spot.room = room
            item.spot = spot

            let event = LocationEvent(kind: .placed, spot: spot, date: item.dateAdded)
            context.insert(event)
            event.item = item
        }

        do {
            try context.save()
        } catch {
            Logger(subsystem: "com.SpotGrid", category: "Upgrade")
                .error("Legacy data upgrade failed to save: \(error.localizedDescription, privacy: .public)")
        }
    }
}
