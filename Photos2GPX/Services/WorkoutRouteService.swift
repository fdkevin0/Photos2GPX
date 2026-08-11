import CoreLocation
import Foundation
import HealthKit

/// A workout from HealthKit together with the GPS route recorded alongside it.
struct WorkoutRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let activityName: String
    let start: Date
    let end: Date
    /// Distance reported by HealthKit, in metres. `nil` when the workout has no
    /// distance sample (e.g. a strength session).
    let healthKitDistance: Double?
    let track: GPXTrack

    var hasRoute: Bool { !track.isEmpty }
    var pointCount: Int { track.pointCount }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum WorkoutServiceError: LocalizedError {
    case healthDataUnavailable

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data is not available on this device."
        }
    }
}

/// Reads workouts and their `HKWorkoutRoute` series from HealthKit.
final class WorkoutRouteService {
    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    }

    func requestAuthorization() async throws {
        guard Self.isAvailable else { throw WorkoutServiceError.healthDataUnavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Every workout overlapping the interval, each with its route flattened into
    /// one track. Workouts without GPS are still returned, with an empty track,
    /// so the UI can say why they contributed nothing.
    func fetchWorkouts(in range: DateInterval) async throws -> [WorkoutRecord] {
        guard Self.isAvailable else { throw WorkoutServiceError.healthDataUnavailable }

        let workouts = try await queryWorkouts(in: range)
        var records: [WorkoutRecord] = []
        records.reserveCapacity(workouts.count)

        for workout in workouts {
            var segments: [GPXTrackSegment] = []
            for route in try await queryRoutes(for: workout) {
                let locations = try await queryLocations(for: route)
                let points = locations
                    .compactMap(GPXPoint.init(location:))
                    .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
                if points.count >= 2 {
                    segments.append(GPXTrackSegment(points: points))
                }
            }

            let name = workout.workoutActivityType.displayName
            let distance = totalDistance(for: workout)
            let track = GPXTrack(
                name: "\(name) – \(Self.trackDateFormatter.string(from: workout.startDate))",
                desc: trackDescription(for: workout, distance: distance),
                type: workout.workoutActivityType.gpxType,
                source: .workout,
                segments: segments
            )
            records.append(
                WorkoutRecord(
                    id: workout.uuid,
                    activityName: name,
                    start: workout.startDate,
                    end: workout.endDate,
                    healthKitDistance: distance,
                    track: track
                )
            )
        }

        return records.sorted { $0.start < $1.start }
    }

    // MARK: - Queries

    private func queryWorkouts(in range: DateInterval) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: [])
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples as? [HKWorkout] ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func queryRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { continuation in
            // No update handler is installed, so the results handler runs exactly once.
            let query = HKAnchoredObjectQuery(
                type: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                anchor: nil,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
                }
            }
            store.execute(query)
        }
    }

    /// `HKWorkoutRouteQuery` delivers locations in batches; the stream collects
    /// them until HealthKit reports the route is done.
    private func queryLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        let store = self.store
        let batches = AsyncThrowingStream<[CLLocation], Error> { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                if let locations, !locations.isEmpty {
                    continuation.yield(locations)
                }
                if done {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                store.stop(query)
            }
            store.execute(query)
        }

        var all: [CLLocation] = []
        for try await batch in batches {
            all.append(contentsOf: batch)
        }
        return all
    }

    // MARK: - Helpers

    /// First available distance statistic for the workout, in metres.
    private func totalDistance(for workout: HKWorkout) -> Double? {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .distanceDownhillSnowSports,
            .distanceWheelchair
        ]
        for identifier in identifiers {
            if let sum = workout.statistics(for: HKQuantityType(identifier))?.sumQuantity() {
                return sum.doubleValue(for: .meter())
            }
        }
        return nil
    }

    private func trackDescription(for workout: HKWorkout, distance: Double?) -> String {
        var parts: [String] = []
        let minutes = workout.duration / 60
        parts.append(String(format: "%.0f min", minutes))
        if let distance {
            parts.append(String(format: "%.2f km", distance / 1000))
        }
        let sourceName = workout.sourceRevision.source.name
        if !sourceName.isEmpty {
            parts.append("recorded by \(sourceName)")
        }
        return parts.joined(separator: " · ")
    }

    private static let trackDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

extension HKWorkoutActivityType {
    /// Human readable name for the activity types most likely to carry a route.
    var displayName: String {
        switch self {
        case .running: "Run"
        case .walking: "Walk"
        case .hiking: "Hike"
        case .cycling: "Cycle"
        case .swimming: "Swim"
        case .wheelchairRunPace, .wheelchairWalkPace: "Wheelchair"
        case .rowing: "Row"
        case .paddleSports: "Paddle"
        case .sailing: "Sailing"
        case .surfingSports: "Surfing"
        case .snowboarding: "Snowboarding"
        case .downhillSkiing: "Downhill Skiing"
        case .crossCountrySkiing: "Cross-Country Skiing"
        case .skatingSports: "Skating"
        case .golf: "Golf"
        case .equestrianSports: "Horse Riding"
        case .hunting: "Hunting"
        case .fishing: "Fishing"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stair Climbing"
        case .highIntensityIntervalTraining: "HIIT"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength Training"
        case .yoga: "Yoga"
        case .other: "Workout"
        default: "Workout"
        }
    }

    /// Value written to `<type>` in the GPX track, using the informal
    /// lowercase vocabulary most GPX consumers understand.
    var gpxType: String {
        switch self {
        case .running: "running"
        case .walking: "walking"
        case .hiking: "hiking"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .rowing: "rowing"
        case .paddleSports: "paddling"
        case .sailing: "sailing"
        case .snowboarding: "snowboarding"
        case .downhillSkiing: "skiing"
        case .crossCountrySkiing: "nordic-skiing"
        case .skatingSports: "skating"
        case .equestrianSports: "riding"
        case .wheelchairRunPace, .wheelchairWalkPace: "wheelchair"
        default: "other"
        }
    }
}
