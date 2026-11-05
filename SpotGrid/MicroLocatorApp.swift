//
//  MicroLocatorApp.swift
//  MicroLocator
//
//  App entry point. The ModelContainer is created once here and injected into the
//  environment; every view reads it via @Environment(\.modelContext) / @Query.
//
//  Minimum deployment target: iOS 17.0
//  Required Info.plist key:   NSCameraUsageDescription
//

import SwiftUI
import SwiftData

@main
struct MicroLocatorApp: App {

    /// Explicit container so schema failures crash loudly at launch (during
    /// development) instead of surfacing as mysterious @Query emptiness later.
    private let container: ModelContainer = {
        // SpotModel and LocationEvent arrived in V1.2. Both are additive, so
        // SwiftData migrates existing stores automatically (lightweight).
        let schema = Schema([RoomModel.self, SpotModel.self, StoredAsset.self, LocationEvent.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
            // 100% offline by design — no CloudKit configuration, ever.
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        // Turn pre-spot items into spots before any view queries the store.
        LegacyDataUpgrader.upgradeIfNeeded(in: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RoomListView()
        }
        .modelContainer(container)
    }
}
