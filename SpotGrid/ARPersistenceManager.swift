//
//  ARPersistenceManager.swift
//  MicroLocator
//
//  Everything needed to turn a live ARSession into durable bytes and back:
//
//    capture:   getCurrentWorldMap(), gated on worldMappingStatus
//    archive:   NSKeyedArchiver (secure coding) + LZFSE compression
//    restore:   NSKeyedUnarchiver → ARWorldMap
//    configure: the single ARWorldTrackingConfiguration used app-wide,
//               optionally seeded with a restored map for relocalization
//
//  Why NSKeyedArchiver? ARWorldMap conforms to NSSecureCoding but not Codable —
//  keyed archiving is Apple's supported serialization path for it. The archived
//  Data survives reboots/app restarts because it's just bytes; what makes the
//  coordinates *usable* again is relocalization (config.initialWorldMap), which
//  re-establishes the identical world origin the coordinates were captured in.
//

// ARWorldMap / ARFrame are not Sendable. @preconcurrency downgrades the strict-
// concurrency diagnostics for this module's types; each isolation crossing below
// is single-reader hand-off, which is why it's safe in practice.
@preconcurrency import ARKit
import Foundation

enum ARPersistenceError: LocalizedError {
    case mappingIncomplete(ARFrame.WorldMappingStatus)
    case captureFailed(underlying: Error?)
    case corruptArchive
    case missingWorldMap

    var errorDescription: String? {
        switch self {
        case .mappingIncomplete:
            return "The room isn't fully mapped yet. Move your device around a little more, then try saving again."
        case .captureFailed(let underlying):
            return underlying?.localizedDescription ?? "ARKit could not capture the world map."
        case .corruptArchive:
            return "The saved room data is corrupted and can't be loaded."
        case .missingWorldMap:
            return "This room has no saved world map."
        }
    }
}

final class ARPersistenceManager {

    // MARK: - Capture

    /// Snapshots the session's world map — anchors included, which is the whole
    /// point: every named item anchor added before this call is serialized
    /// inside the map and comes back for free on relocalization.
    ///
    /// Gated on mapping status: saving a `.limited` map produces a file that
    /// relocalizes poorly or not at all, which reads to the user as "the app
    /// forgot where my passport is". Fail loudly instead.
    @MainActor
    func captureWorldMap(from session: ARSession) async throws -> ARWorldMap {
        let status = session.currentFrame?.worldMappingStatus ?? .notAvailable
        guard status == .mapped || status == .extending else {
            throw ARPersistenceError.mappingIncomplete(status)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Completion arrives on the session's delegate queue (main by
            // default). ARWorldMap crosses the continuation exactly once.
            session.getCurrentWorldMap { worldMap, error in
                if let worldMap {
                    continuation.resume(returning: worldMap)
                } else {
                    continuation.resume(throwing: ARPersistenceError.captureFailed(underlying: error))
                }
            }
        }
    }

    // MARK: - Serialization

    /// ARWorldMap → Data (secure keyed archive, then LZFSE).
    /// Maps run 10–60 MB raw; LZFSE typically halves that at negligible CPU cost,
    /// which matters both for disk and for SwiftData external-storage churn.
    func archive(_ worldMap: ARWorldMap) throws -> Data {
        let raw = try NSKeyedArchiver.archivedData(
            withRootObject: worldMap,
            requiringSecureCoding: true
        )
        return try (raw as NSData).compressed(using: .lzfse) as Data
    }

    /// Data → ARWorldMap. Tolerates uncompressed input so archives written before
    /// compression was introduced (or by tests) still load.
    func unarchive(_ data: Data) throws -> ARWorldMap {
        let raw = (try? (data as NSData).decompressed(using: .lzfse) as Data) ?? data
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: raw) else {
            throw ARPersistenceError.corruptArchive
        }
        return map
    }

    // MARK: - Configuration factory

    enum TrackingPurpose {
        /// Scanning/tagging: needs plane detection (+ LiDAR mesh) for raycasts.
        case capture
        /// Locating: relocalization + rendering only — no raycasts happen, so
        /// plane detection and scene reconstruction are pure battery/CPU cost.
        case locate
    }

    /// The single source of ARWorldTrackingConfigurations, now purpose-split.
    /// Both purposes share worldAlignment and texturing settings so a map
    /// captured by one relocalizes cleanly under the other — relocalization
    /// matches visual features and is unaffected by plane/mesh settings.
    ///
    /// - Parameter initialWorldMap: pass a restored map to enter relocalization
    ///   mode; leave nil for a fresh tracking run.
    func trackingConfiguration(
        for purpose: TrackingPurpose,
        initialWorldMap: ARWorldMap? = nil
    ) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity

        // We render exclusively with UnlitMaterial, so environment texturing
        // buys nothing — leaving it off saves measurable CPU/GPU on every
        // device, Pro and non-Pro alike.
        config.environmentTexturing = .none

        switch purpose {
        case .capture:
            config.planeDetection = [.horizontal, .vertical]
            // On LiDAR hardware the scene mesh makes tap raycasts land
            // precisely on drawer fronts and shelf edges.
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }
        case .locate:
            config.planeDetection = []
            // No sceneReconstruction here: dropping the mesh is the single
            // biggest thermal/battery win in Locate mode on Pro devices.
        }

        config.initialWorldMap = initialWorldMap
        return config
    }
}
