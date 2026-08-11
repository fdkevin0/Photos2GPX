import CoreLocation
import XCTest
@testable import Photos2GPX

final class TrackSmootherTests: XCTestCase {
    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func meters(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    // MARK: - Simplification

    func testSimplifyCollapsesCollinearPoints() {
        // Five points on a straight north-south line, ~11 m apart.
        let line = (0..<5).map { coordinate(45.0 + Double($0) * 0.0001, 9.0) }
        let simplified = TrackSmoother.simplify(line, tolerance: 5)

        XCTAssertEqual(simplified.count, 2)
        XCTAssertEqual(simplified.first?.latitude, line.first?.latitude)
        XCTAssertEqual(simplified.last?.latitude, line.last?.latitude)
    }

    func testSimplifyKeepsAMeaningfulDetour() {
        let line = [
            coordinate(45.0000, 9.0),
            coordinate(45.0001, 9.0),
            // ~78 m to the east — well beyond the tolerance.
            coordinate(45.0002, 9.001),
            coordinate(45.0003, 9.0),
            coordinate(45.0004, 9.0)
        ]
        let simplified = TrackSmoother.simplify(line, tolerance: 5)

        XCTAssertGreaterThanOrEqual(simplified.count, 3)
        XCTAssertTrue(simplified.contains { abs($0.longitude - 9.001) < 1e-9 })
    }

    func testSimplifyLeavesShortInputsAlone() {
        let pair = [coordinate(45, 9), coordinate(46, 9)]
        XCTAssertEqual(TrackSmoother.simplify(pair, tolerance: 5).count, 2)
        XCTAssertEqual(TrackSmoother.simplify([], tolerance: 5).count, 0)
    }

    // MARK: - Interpolation

    func testCatmullRomAddsSamplesAndKeepsEndpoints() {
        let corner = [
            coordinate(45.0000, 9.0000),
            coordinate(45.0010, 9.0000),
            coordinate(45.0010, 9.0010)
        ]
        let curve = TrackSmoother.catmullRom(corner, spacing: 10, maximumSamplesPerSegment: 24)

        XCTAssertGreaterThan(curve.count, corner.count)
        XCTAssertLessThan(meters(curve[0], corner[0]), 0.5)
        XCTAssertLessThan(meters(curve[curve.count - 1], corner[2]), 0.5)
    }

    func testCurveStaysNearTheOriginalPath() {
        // A gentle arc sampled every few metres, so "distance to the nearest
        // input vertex" is a fair stand-in for "distance to the input path".
        let arc = (0..<60).map { step -> CLLocationCoordinate2D in
            let angle = Double(step) / 59 * .pi / 2
            return coordinate(45.0 + 0.002 * sin(angle), 9.0 + 0.002 * (1 - cos(angle)))
        }
        let curve = TrackSmoother.smooth(arc, options: TrackSmoother.Options(simplifyTolerance: 1))

        for point in curve {
            let nearest = arc.map { meters($0, point) }.min() ?? .greatestFiniteMagnitude
            XCTAssertLessThan(nearest, 15, "curve strayed \(nearest) m from the input path")
        }
    }

    func testSmoothPassesThroughShortInputs() {
        let pair = [coordinate(45, 9), coordinate(45.001, 9)]
        XCTAssertEqual(TrackSmoother.smooth(pair).count, 2)
    }

    func testSmoothHandlesDuplicatePoints() {
        let repeated = Array(repeating: coordinate(45, 9), count: 6)
        let smoothed = TrackSmoother.smooth(repeated)
        XCTAssertFalse(smoothed.isEmpty)
        XCTAssertTrue(smoothed.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite })
    }

    func testDecimateRespectsTheLimitAndKeepsEnds() {
        let line = (0..<1000).map { coordinate(45.0 + Double($0) * 0.0001, 9.0) }
        let thinned = TrackSmoother.decimate(line, to: 50)

        XCTAssertEqual(thinned.count, 50)
        XCTAssertEqual(thinned.first?.latitude, line.first?.latitude)
        XCTAssertEqual(thinned.last?.latitude, line.last?.latitude)
    }

    func testSmoothRespectsTheOutputCeiling() {
        // A long meander, so simplification cannot collapse it to a straight line.
        let long = (0..<4000).map { step in
            coordinate(45.0 + Double(step) * 0.0002, 9.0 + 0.0005 * sin(Double(step) / 10))
        }
        var options = TrackSmoother.Options()
        options.maximumOutputPoints = 500
        XCTAssertLessThanOrEqual(TrackSmoother.smooth(long, options: options).count, 500)
    }

    // MARK: - Geometry helpers

    func testPerpendicularDistance() {
        let start = TrackSmoother.PlanePoint(x: 0, y: 0)
        let end = TrackSmoother.PlanePoint(x: 10, y: 0)
        let off = TrackSmoother.PlanePoint(x: 5, y: 3)

        XCTAssertEqual(TrackSmoother.perpendicularDistance(off, from: start, to: end), 3, accuracy: 0.0001)
        // Degenerate line: falls back to point-to-point distance.
        XCTAssertEqual(
            TrackSmoother.perpendicularDistance(off, from: start, to: start),
            hypot(5, 3),
            accuracy: 0.0001
        )
    }
}
