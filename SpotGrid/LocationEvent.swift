//
//  LocationEvent.swift
//  SpotGrid
//
//  One entry in an item's location history: "placed in Bedroom › Drawer 3 on
//  12 Oct", "moved to Hall › Shelf 2 on 15 Oct". The first event is the item's
//  original location, which is how the app answers "where was this originally?"
//  after someone moves it.
//

import Foundation
import SwiftData

enum LocationEventKind: String {
    case placed
    case moved
}

@Model
final class LocationEvent {

    @Attribute(.unique) var id: UUID
    var date: Date
    var kindRaw: String

    /// Names are snapshotted so the history stays readable after the spot or
    /// room is renamed or deleted.
    var roomName: String
    var spotName: String

    /// The spot the item arrived in. Deliberately not a relationship: history
    /// must outlive the spot. Resolved on demand for "Guide me there".
    var spotID: UUID?

    var item: StoredAsset?

    init(kind: LocationEventKind, spot: SpotModel, date: Date = .now) {
        self.id = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.roomName = spot.room?.name ?? ""
        self.spotName = spot.name
        self.spotID = spot.id
    }

    var kind: LocationEventKind {
        LocationEventKind(rawValue: kindRaw) ?? .moved
    }
}
