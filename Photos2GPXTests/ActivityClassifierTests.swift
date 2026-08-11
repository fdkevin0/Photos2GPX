import CoreLocation
import XCTest
@testable import Photos2GPX

final class ActivityClassifierTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 45, longitude: 9)
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a straight northbound track that travels each leg at the given
    /// speed. Timestamps and positions are consistent, so the classifier has to
    /// derive the speed itself — none is written into the points.
    private func track(
        legs: [(speed: Double, duration: TimeInterval)],
        sampleInterval: TimeInterval = 5
    ) -> [GPXPoint] {
        var points: [GPXPoint] = []
        var elapsed: TimeInterval = 0
        var metersNorth = 0.0

        points.append(
            GPXPoint(latitude: origin.latitude, longitude: origin.longitude, timestamp: epoch)
        )

        for leg in legs {
            var travelled: TimeInterval = 0
            while travelled < leg.duration {
                let step = min(sampleInterval, leg.duration - travelled)
                travelled += step
                elapsed += step
                metersNorth += leg.speed * step
                points.append(
                    GPXPoint(
                        latitude: origin.latitude + metersNorth / 111_132.0,
                        longitude: origin.longitude,
                        timestamp: epoch.addingTimeInterval(elapsed)
                    )
                )
            }
        }
        return points
    }

    // MARK: - Speed derivation

    func testDerivesSpeedFromConsecutiveFixes() {
        let points = track(legs: [(speed: 10, duration: 60)])
        let speeds = ActivityClassifier.speeds(for: points)

        XCTAssertEqual(speeds.count, points.count)
        // Allow for the ellipsoid vs. the flat 111_132 m/degree used above.
        for speed in speeds.dropFirst() {
            XCTAssertEqual(speed, 10, accuracy: 0.3)
        }
    }

    func testPrefersRecordedSpeedOverDerivedSpeed() {
        var points = track(legs: [(speed: 10, duration: 30)])
        for index in points.indices {
            points[index].speed = 3
        }
        XCTAssertTrue(ActivityClassifier.speeds(for: points).allSatisfy { abs($0 - 3) < 0.001 })
    }

    func testIgnoresSpeedAcrossALongGap() {
        let start = GPXPoint(latitude: 45, longitude: 9, timestamp: epoch)
        // 100 km later, two hours on: a gap, not a 14 m/s journey.
        let end = GPXPoint(
            latitude: 45.9,
            longitude: 9,
            timestamp: epoch.addingTimeInterval(7200)
        )
        let speeds = ActivityClassifier.speeds(for: [start, end])
        XCTAssertEqual(speeds.last, 0, "a gap longer than the limit should not become a speed")
    }

    // MARK: - Classification

    func testClassifiesAWalk() {
        let segments = ActivityClassifier.segments(for: track(legs: [(speed: 1.4, duration: 600)]))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.mode, .walking)
        XCTAssertEqual(segments.first?.isInferred, true)
    }

    func testClassifiesARun() {
        let segments = ActivityClassifier.segments(for: track(legs: [(speed: 3.3, duration: 900)]))
        XCTAssertEqual(segments.first?.mode, .running)
    }

    func testClassifiesACycle() {
        let segments = ActivityClassifier.segments(for: track(legs: [(speed: 6.5, duration: 900)]))
        XCTAssertEqual(segments.first?.mode, .cycling)
    }

    func testClassifiesDriving() {
        let segments = ActivityClassifier.segments(for: track(legs: [(speed: 22, duration: 900)]))
        XCTAssertEqual(segments.first?.mode, .driving)
    }

    func testClassifiesFlying() {
        let segments = ActivityClassifier.segments(
            for: track(legs: [(speed: 220, duration: 1800)], sampleInterval: 15)
        )
        XCTAssertEqual(segments.first?.mode, .flying)
    }

    func testSplitsAWalkFollowedByADrive() {
        let points = track(legs: [
            (speed: 1.3, duration: 600),
            (speed: 20, duration: 900)
        ])
        let segments = ActivityClassifier.segments(for: points)

        XCTAssertEqual(segments.count, 2, "expected one walking and one driving segment")
        XCTAssertEqual(segments.first?.mode, .walking)
        XCTAssertEqual(segments.last?.mode, .driving)
        XCTAssertLessThan(segments[0].start ?? .distantFuture, segments[1].start ?? .distantPast)
    }

    func testAbsorbsAShortStopInsideAWalk() {
        let points = track(legs: [
            (speed: 1.4, duration: 400),
            // Waiting at a crossing for 15 seconds.
            (speed: 0, duration: 15),
            (speed: 1.4, duration: 400)
        ])
        let segments = ActivityClassifier.segments(for: points)

        XCTAssertEqual(segments.count, 1, "a 15 s pause should not become its own segment")
        XCTAssertEqual(segments.first?.mode, .walking)
    }

    func testKeepsALongStop() {
        let points = track(legs: [
            (speed: 1.4, duration: 400),
            (speed: 0, duration: 600),
            (speed: 1.4, duration: 400)
        ])
        let modes = ActivityClassifier.segments(for: points).map(\.mode)
        XCTAssertTrue(modes.contains(.stationary), "a ten-minute stop is real; got \(modes)")
    }

    func testSegmentsCarryPlausibleStatistics() throws {
        let segments = ActivityClassifier.segments(for: track(legs: [(speed: 5, duration: 600)]))
        let segment = try XCTUnwrap(segments.first)

        // 5 m/s for 600 s ≈ 3 km.
        XCTAssertEqual(segment.distance, 3000, accuracy: 150)
        XCTAssertEqual(segment.duration, 600, accuracy: 15)
        XCTAssertEqual(segment.averageSpeed, 5, accuracy: 0.5)
        XCTAssertGreaterThan(segment.confidence, 0.8)
    }

    func testConsecutiveSegmentsShareABoundaryPointSoTheyDrawJoined() {
        let points = track(legs: [
            (speed: 1.3, duration: 600),
            (speed: 20, duration: 900)
        ])
        let segments = ActivityClassifier.segments(for: points)
        guard segments.count >= 2 else { return XCTFail("expected two segments") }

        let firstEnd = segments[0].points.last
        let secondStart = segments[1].points.first
        XCTAssertEqual(firstEnd?.latitude, secondStart?.latitude)
        XCTAssertEqual(firstEnd?.longitude, secondStart?.longitude)
    }

    func testTooFewPointsProduceNoSegments() {
        XCTAssertTrue(ActivityClassifier.segments(for: []).isEmpty)
        XCTAssertTrue(
            ActivityClassifier.segments(for: [GPXPoint(latitude: 45, longitude: 9, timestamp: epoch)]).isEmpty
        )
    }

    // MARK: - Recorded workouts win over inference

    func testRecordedWorkoutTypeIsTrustedOverSpeed() {
        // Points that look like cycling, on a track HealthKit says was a run.
        let points = track(legs: [(speed: 6.5, duration: 600)])
        let workout = GPXTrack(
            name: "Run",
            type: "running",
            source: .workout,
            segments: [GPXTrackSegment(points: points)]
        )
        let segments = ActivityClassifier.segments(for: workout)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.mode, .running)
        XCTAssertEqual(segments.first?.isInferred, false)
        XCTAssertEqual(segments.first?.confidence, 1)
    }

    func testUnmappableWorkoutTypeFallsBackToInference() {
        let points = track(legs: [(speed: 1.4, duration: 600)])
        let workout = GPXTrack(
            name: "Row",
            type: "rowing",
            source: .workout,
            segments: [GPXTrackSegment(points: points)]
        )
        let segments = ActivityClassifier.segments(for: workout)

        XCTAssertEqual(segments.first?.mode, .walking)
        XCTAssertEqual(segments.first?.isInferred, true)
    }

    // MARK: - Thresholds

    func testTrainIsSeparatedFromDrivingByItsPeak() {
        XCTAssertEqual(TransportMode.classify(medianSpeed: 25, peakSpeed: 30), .driving)
        XCTAssertEqual(TransportMode.classify(medianSpeed: 25, peakSpeed: 50), .transit)
        XCTAssertEqual(TransportMode.classify(medianSpeed: 200, peakSpeed: 240), .flying)
    }

    func testMedianAndPercentileHelpers() {
        XCTAssertEqual(ActivityClassifier.median(of: [1, 5, 3]), 3)
        XCTAssertEqual(ActivityClassifier.median(of: []), 0)
        XCTAssertEqual(ActivityClassifier.percentile(of: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], 0.95), 9)
    }

    func testRollingMedianRemovesASingleSpike() {
        let noisy = [1.0, 1.0, 1.0, 90.0, 1.0, 1.0, 1.0]
        let filtered = ActivityClassifier.rollingMedian(noisy, window: 5)
        XCTAssertTrue(filtered.allSatisfy { $0 < 2 }, "spike survived: \(filtered)")
    }
}
