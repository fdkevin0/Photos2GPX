import Foundation
import SwiftUI

/// How the user was most likely moving during a stretch of a track.
///
/// Modes are inferred from speed, which is a heuristic: a car at 25 m/s and a
/// train at 25 m/s look identical to a GPS trace. Peak speed and sustained
/// median speed together separate the common cases; anything genuinely
/// ambiguous is reported with a low confidence rather than a confident guess.
enum TransportMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case driving
    case transit
    case flying
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stationary: return "Stopped"
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .driving: return "Driving"
        case .transit: return "Train"
        case .flying: return "Flying"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .stationary: return "pause.circle.fill"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        case .transit: return "tram.fill"
        case .flying: return "airplane"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .stationary: return .gray
        case .walking: return .green
        case .running: return .orange
        case .cycling: return .teal
        case .driving: return .blue
        case .transit: return .purple
        case .flying: return .pink
        case .unknown: return .secondary
        }
    }

    /// Value used for `<type>` when this mode describes an exported track.
    var gpxType: String {
        switch self {
        case .stationary: return "stationary"
        case .walking: return "walking"
        case .running: return "running"
        case .cycling: return "cycling"
        case .driving: return "driving"
        case .transit: return "transit"
        case .flying: return "flying"
        case .unknown: return "other"
        }
    }

    /// Speed boundaries in metres per second.
    enum Threshold {
        /// Below this the receiver is drifting, not moving.
        static let stationary = 0.4
        /// ~7.9 km/h — brisk walking tops out here.
        static let walkingCeiling = 2.2
        /// ~15.8 km/h — a fast runner, a slow cyclist.
        static let runningCeiling = 4.4
        /// ~32 km/h — above this a bicycle is unlikely to be sustained.
        static let cyclingCeiling = 8.9
        /// ~140 km/h — plausible upper bound for road traffic.
        static let drivingCeiling = 39.0
        /// ~250 km/h — only aircraft sustain this.
        static let flying = 69.0
        /// A burst this fast (~162 km/h) with a high median means rail, not road.
        static let transitPeak = 45.0
        static let transitMedian = 22.0
    }

    /// Coarse label for a single speed sample, used before smoothing.
    static func instantaneous(speed: Double) -> TransportMode {
        guard speed.isFinite, speed >= 0 else { return .unknown }
        switch speed {
        case ..<Threshold.stationary: return .stationary
        case ..<Threshold.walkingCeiling: return .walking
        case ..<Threshold.runningCeiling: return .running
        case ..<Threshold.cyclingCeiling: return .cycling
        case ..<Threshold.drivingCeiling: return .driving
        case ..<Threshold.flying: return .transit
        default: return .flying
        }
    }

    /// Final label for a run of samples, judged on its sustained speed and its
    /// fastest burst. Stops inside a journey do not demote the whole journey,
    /// because the median ignores them.
    static func classify(medianSpeed: Double, peakSpeed: Double) -> TransportMode {
        guard medianSpeed.isFinite, peakSpeed.isFinite else { return .unknown }
        if peakSpeed >= Threshold.flying { return .flying }
        if medianSpeed < Threshold.stationary { return .stationary }
        if peakSpeed >= Threshold.transitPeak, medianSpeed >= Threshold.transitMedian {
            return .transit
        }
        return instantaneous(speed: medianSpeed)
    }

    /// Maps the `<type>` written for a HealthKit workout back to a mode, so a
    /// recorded activity is displayed as fact instead of being re-guessed.
    init?(gpxType: String) {
        switch gpxType.lowercased() {
        case "running": self = .running
        case "walking", "hiking": self = .walking
        case "cycling": self = .cycling
        case "driving": self = .driving
        case "transit": self = .transit
        case "flying": self = .flying
        // Rowing, paddling, skiing and friends move at their own pace and are
        // not one of the modes this app can distinguish.
        default: return nil
        }
    }
}

extension GPXSource {
    /// Palette used when the map is coloured by where the data came from rather
    /// than by inferred activity.
    var color: Color {
        switch self {
        case .workout: return .blue
        case .photos: return .orange
        case .imported: return .green
        }
    }
}
