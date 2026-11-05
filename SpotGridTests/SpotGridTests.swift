//
//  SpotGridTests.swift
//  SpotGridTests
//
//  Created by Ankit Teotia on 11/07/26.
//

import Foundation
import SwiftData
import Testing
import UIKit
import simd
@testable import SpotGrid

@MainActor
struct AnchorNamingTests {

    @Test func spotAnchorNamesUseTheSpotPrefix() {
        let id = UUID()
        #expect(AnchorNaming.spotAnchorName(for: id) == "spot:\(id.uuidString)")
    }

    @Test func legacyAndSpotAnchorsAreBothRecognised() {
        let id = UUID()
        #expect(AnchorNaming.isAppAnchor(AnchorNaming.spotAnchorName(for: id)))
        #expect(AnchorNaming.isAppAnchor(AnchorNaming.legacyAssetAnchorName(for: id)))
        #expect(!AnchorNaming.isAppAnchor(nil))
        #expect(!AnchorNaming.isAppAnchor("plane"))
    }
}

@MainActor
struct FormattingTests {

    @Test func distancesUnderAMetreAreCentimetres() {
        #expect(DistanceFormatting.text(meters: 0.45) == "45 cm")
    }

    @Test func distancesFromAMetreAreMetres() {
        #expect(DistanceFormatting.text(meters: 1) == "1.0 m")
        #expect(DistanceFormatting.text(meters: 2.34) == "2.3 m")
    }
}

@MainActor
struct ImageSupportTests {

    @Test func cameraFramesAreRotatedUprightForEveryOrientation() {
        #expect(ImageSupport.imageOrientation(for: .portrait) == .right)
        #expect(ImageSupport.imageOrientation(for: .portraitUpsideDown) == .left)
        #expect(ImageSupport.imageOrientation(for: .landscapeLeft) == .down)
        #expect(ImageSupport.imageOrientation(for: .landscapeRight) == .up)
    }

    @Test func photosAreDownscaledAndGetAThumbnail() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format)
            .image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            }

        let pair = try #require(ImageSupport.photoPair(from: large, maxDimension: 1600))
        let photo = try #require(UIImage(data: pair.photo))
        let thumbnail = try #require(UIImage(data: pair.thumbnail))

        #expect(max(photo.size.width, photo.size.height) == 1600)
        #expect(max(thumbnail.size.width, thumbnail.size.height) == ImageSupport.thumbnailMaxDimension)
    }
}

@MainActor
struct InventoryTests {

    /// The container must outlive its context, so each test keeps it in scope.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RoomModel.self, SpotModel.self, StoredAsset.self, LocationEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeSpot(_ name: String, in room: RoomModel, context: ModelContext) -> SpotModel {
        let spot = SpotModel(name: name, position: SIMD3<Float>(1, 0, 2))
        context.insert(spot)
        spot.room = room
        return spot
    }

    @Test func addingAnItemRecordsWhereItWasPlaced() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let room = RoomModel(name: "Bedroom")
        context.insert(room)
        let drawer = makeSpot("Drawer 3", in: room, context: context)

        let passport = Inventory.addItem(named: "Passport", to: drawer, in: context)

        #expect(passport.spot?.id == drawer.id)
        #expect(passport.room?.id == room.id)
        #expect(passport.worldPosition == drawer.worldPosition)
        #expect(passport.sortedHistory.map(\.kind) == [.placed])
        #expect(!passport.hasMoved)
    }

    @Test func movingKeepsTheOriginalLocationInHistory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let bedroom = RoomModel(name: "Bedroom")
        let hall = RoomModel(name: "Hall")
        context.insert(bedroom)
        context.insert(hall)
        let drawer = makeSpot("Drawer 3", in: bedroom, context: context)
        let shelf = makeSpot("Shelf 2", in: hall, context: context)

        let passport = Inventory.addItem(named: "Passport", to: drawer, in: context)
        Inventory.move(passport, to: shelf, in: context)

        #expect(passport.spot?.id == shelf.id)
        #expect(passport.room?.id == hall.id)
        #expect(passport.hasMoved)
        #expect(passport.lastConfirmedDate != nil)
        #expect(passport.originalEvent?.spotID == drawer.id)
        #expect(passport.sortedHistory.map(\.spotName) == ["Drawer 3", "Shelf 2"])
        #expect(passport.sortedHistory.map(\.roomName) == ["Bedroom", "Hall"])
    }

    @Test func movingToTheSameSpotDoesNothing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let room = RoomModel(name: "Bedroom")
        context.insert(room)
        let drawer = makeSpot("Drawer 3", in: room, context: context)
        let passport = Inventory.addItem(named: "Passport", to: drawer, in: context)

        Inventory.move(passport, to: drawer, in: context)

        #expect(passport.history.count == 1)
    }

    @Test func searchMatchesItemSpotAndRoomNames() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let room = RoomModel(name: "Bedroom")
        context.insert(room)
        let drawer = makeSpot("Almirah drawer 2", in: room, context: context)
        let passport = Inventory.addItem(named: "Passport", notes: "blue folder", to: drawer, in: context)

        #expect(passport.matches("pass"))
        #expect(passport.matches("BLUE"))
        #expect(passport.matches("almirah"))
        #expect(passport.matches("bedroom"))
        #expect(!passport.matches("kitchen"))
    }

    @Test func legacyItemsBecomeSpotsThatKeepTheirAnchor() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let room = RoomModel(name: "Bedroom")
        context.insert(room)
        let legacy = StoredAsset(name: "Passport", position: SIMD3<Float>(0.5, 1, -2))
        context.insert(legacy)
        legacy.room = room

        LegacyDataUpgrader.upgradeIfNeeded(in: context)
        LegacyDataUpgrader.upgradeIfNeeded(in: context)   // idempotent

        let spot = try #require(legacy.spot)
        #expect(room.spots.count == 1)
        #expect(spot.anchorName == AnchorNaming.legacyAssetAnchorName(for: legacy.id))
        #expect(spot.worldPosition == legacy.worldPosition)
        #expect(legacy.history.count == 1)
    }
}
