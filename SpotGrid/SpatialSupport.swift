//
//  SpatialSupport.swift
//  MicroLocator
//
//  Small shared spatial vocabulary: the anchor-name contract that links
//  StoredAsset ↔ ARAnchor, hardware capability gates, and user-facing labels
//  for ARKit's world mapping status.
//

import ARKit
import RealityKit
import RoomPlan

// MARK: - Anchor naming contract

/// The single place that defines how a StoredAsset's identity is embedded into
/// the ARWorldMap. If this ever drifts between writer (tagging) and reader
/// (locating), relocalized anchors silently stop matching — so it lives here
/// and nowhere else.
enum AnchorNaming {
    static let prefix = "asset:"

    static func name(for assetID: UUID) -> String {
        prefix + assetID.uuidString
    }

    static func assetID(from anchorName: String?) -> UUID? {
        guard let anchorName, anchorName.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(anchorName.dropFirst(prefix.count)))
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
