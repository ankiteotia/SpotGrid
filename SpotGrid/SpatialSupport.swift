//
//  SpatialSupport.swift
//  SpotGrid
//
//  Small shared spatial vocabulary: the anchor-name contract that links
//  SpotModel ↔ ARAnchor, hardware capability gates, and user-facing labels
//  for ARKit's world mapping status.
//

import ARKit
import Foundation
import RealityKit
import RoomPlan

// MARK: - Anchor naming contract

/// The single place that defines how a spot's identity is embedded into the
/// ARWorldMap. If this ever drifts between writer (tagging) and reader
/// (locating), relocalized anchors silently stop matching — so it lives here
/// and nowhere else. `SpotModel.anchorName` stores the result.
enum AnchorNaming {
    /// Current scheme (V1.2+): one anchor per spot.
    static let spotPrefix = "spot:"

    /// Pre-spot scheme: one anchor per item. Maps saved by older builds still
    /// contain these, and upgraded spots keep pointing at them — readers must
    /// understand this prefix forever.
    static let legacyAssetPrefix = "asset:"

    static func spotAnchorName(for spotID: UUID) -> String {
        spotPrefix + spotID.uuidString
    }

    static func legacyAssetAnchorName(for assetID: UUID) -> String {
        legacyAssetPrefix + assetID.uuidString
    }

    /// True for any anchor this app wrote (spot or legacy item anchor), as
    /// opposed to ARKit's own plane/mesh anchors.
    static func isAppAnchor(_ anchorName: String?) -> Bool {
        guard let anchorName else { return false }
        return anchorName.hasPrefix(spotPrefix) || anchorName.hasPrefix(legacyAssetPrefix)
    }
}

// MARK: - Distance formatting

enum DistanceFormatting {
    /// "45 cm" under a metre, "2.3 m" from there on.
    static func text(meters: Float) -> String {
        meters < 1
            ? String(format: "%.0f cm", meters * 100)
            : String(format: "%.1f m", meters)
    }
}

// MARK: - Hardware gates

enum DeviceCapabilities {

    /// How this device captures a room. RoomPlan is a LiDAR-only *enhancement*,
    /// not the app's floor — the true floor is plain ARKit world tracking,
    /// which every iOS 17-capable iPhone (A12 / iPhone XS-and-later) supports.
    /// ARWorldMap persistence + relocalization are ARKit 2-era and work on both
    /// paths identically.
    enum CaptureStrategy {
        /// LiDAR: RoomPlan structural scan feeds straight into tagging, with
        /// mesh-precise raycasts.
        case roomPlanAssisted
        /// Non-LiDAR: a manual feature-mapping walk replaces the RoomPlan
        /// phase, then the identical tagging / persistence / Locate machinery.
        case manualMapping
    }

    static var captureStrategy: CaptureStrategy {
        supportsRoomCapture ? .roomPlanAssisted : .manualMapping
    }

    /// RoomPlan requires LiDAR.
    static var supportsRoomCapture: Bool { RoomCaptureSession.isSupported }

    static var supportsWorldTracking: Bool { ARWorldTrackingConfiguration.isSupported }

    static var supportsSceneReconstruction: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
}

// MARK: - Mapping status → UI

extension ARFrame.WorldMappingStatus {

    /// Good enough to persist? Saving `.limited` maps produces archives that
    /// relocalize badly, so the save button gates on this.
    var isSufficientForSaving: Bool {
        self == .mapped || self == .extending
    }

    var userLabel: String {
        switch self {
        case .notAvailable: return "Initializing…"
        case .limited:      return "Keep looking around"
        case .extending:    return "Mapping — good"
        case .mapped:       return "Mapped — ready to save"
        @unknown default:   return "Mapping…"
        }
    }
}

// MARK: - ARView performance tuning

extension ARView {
    /// Shared render tuning for every AR surface in the app. We draw flat,
    /// unlit guidance geometry, so the cinematic camera effects and lighting
    /// passes are pure cost — disabling them noticeably helps frame pacing,
    /// thermals, and battery, most of all on non-Pro hardware.
    func applyGuidanceRenderTuning() {
        renderOptions.formUnion([
            .disableMotionBlur,
            .disableDepthOfField,
            .disableCameraGrain,
            .disableHDR,
            .disablePersonOcclusion,
            .disableGroundingShadows,
            .disableAREnvironmentLighting,
        ])
    }
}
