//
//  GuidanceHaptics.swift
//  MicroLocator
//
//  Geiger-counter style guidance: haptic pulses whose cadence and weight scale
//  with proximity to the target. Far away = slow light ticks; closing in =
//  rapid heavy taps; arrival = a distinct success notification. Lets the user
//  navigate half by feel, without staring at the distance label.
//
//  Uses UIFeedbackGenerator (not CoreHaptics) deliberately: zero setup, works
//  on every supported device, and degrades to no-op silently where haptics
//  are unavailable (e.g. most iPads).
//

import UIKit

@MainActor
final class GuidanceHaptics {

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()

    private var clock: TimeInterval = 0
    private var nextPulseAt: TimeInterval = 0

    /// Warm up the Taptic Engine so the first pulse isn't late.
    func prepare() {
        light.prepare()
        medium.prepare()
        heavy.prepare()
        notification.prepare()
    }

    /// Call every frame from the guidance tick. Internally rate-limits itself
    /// to the distance-appropriate cadence.
    func update(distance: Float, deltaTime: TimeInterval) {
        clock += deltaTime
        guard clock >= nextPulseAt else { return }

        let interval: TimeInterval
        switch distance {
        case ..<0.8:  interval = 0.18   // rapid — right on top of it
        case ..<1.5:  interval = 0.35
        case ..<3.0:  interval = 0.70
        case ..<5.0:  interval = 1.20
        default:      interval = 2.00   // slow reassurance tick
        }

        switch distance {
        case ..<1.5:  heavy.impactOccurred()
        case ..<3.0:  medium.impactOccurred()
        default:      light.impactOccurred()
        }

        nextPulseAt = clock + interval
    }

    /// One-shot success pattern when the user reaches the target.
    func arrival() {
        notification.notificationOccurred(.success)
    }
}
