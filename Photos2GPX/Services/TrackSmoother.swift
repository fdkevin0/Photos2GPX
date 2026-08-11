import CoreLocation
import Foundation

/// Turns a raw GPS trace into a curve that reads as a path rather than a chain
/// of straight hops.
///
/// Two stages: Ramer–Douglas–Peucker throws away points that carry no shape
/// information (and with them most receiver jitter), then a centripetal
/// Catmull–Rom spline re-samples the survivors densely. `MapPolyline` still
/// draws straight lines between the coordinates it is handed — the curve comes
/// from feeding it enough of them.
enum TrackSmoother {
    /// Working coordinate in metres, local to one track.
    struct PlanePoint: Hashable {
        var x: Double
        var y: Double
    }

    /// Equirectangular projection anchored at a track's mean latitude. Accurate
    /// to well under a metre over the spans a single track covers, and far
    /// cheaper than doing the geodesy properly.
    struct Projection {
        static let metersPerDegreeLatitude = 111_132.0

        let originLatitude: Double
        let metersPerDegreeLongitude: Double

        init(latitude: Double) {
            originLatitude = latitude
            metersPerDegreeLongitude = 111_320.0 * cos(latitude * .pi / 180)
        }

        init(coordinates: [CLLocationCoordinate2D]) {
            let mean = coordinates.isEmpty
                ? 0
                : coordinates.reduce(0) { $0 + $1.latitude } / Double(coordinates.count)
            self.init(latitude: mean)
        }

        func project(_ coordinate: CLLocationCoordinate2D) -> PlanePoint {
            PlanePoint(
                x: coordinate.longitude * metersPerDegreeLongitude,
                y: coordinate.latitude * Projection.metersPerDegreeLatitude
            )
        }

        func unproject(_ point: PlanePoint) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: point.y / Projection.metersPerDegreeLatitude,
                longitude: metersPerDegreeLongitude == 0 ? 0 : point.x / metersPerDegreeLongitude
            )
        }
    }

    struct Options: Hashable, Sendable {
        /// Points closer than this to the line they sit on are dropped.
        var simplifyTolerance: CLLocationDistance = 6
        /// Target spacing between generated curve samples.
        var sampleSpacing: CLLocationDistance = 12
        /// Ceiling on samples for one input segment, so a 200 km flight leg does
        /// not generate 20,000 points on its own.
        var maximumSamplesPerSegment = 24
        /// Ceiling on the whole output; anything longer is decimated evenly.
        var maximumOutputPoints = 20_000

        static let `default` = Options()
    }

    /// Simplify, then interpolate. Fewer than three points cannot describe a
    /// curve, so they are returned untouched.
    static func smooth(
        _ coordinates: [CLLocationCoordinate2D],
        options: Options = .default
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 3 else { return coordinates }
        let simplified = simplify(coordinates, tolerance: options.simplifyTolerance)
        let curved = catmullRom(
            simplified,
            spacing: options.sampleSpacing,
            maximumSamplesPerSegment: options.maximumSamplesPerSegment
        )
        return decimate(curved, to: options.maximumOutputPoints)
    }

    // MARK: - Simplification

    /// Ramer–Douglas–Peucker, iterative so that a long track cannot blow the
    /// stack. `tolerance` is in metres.
    static func simplify(
        _ coordinates: [CLLocationCoordinate2D],
        tolerance: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2, tolerance > 0 else { return coordinates }

        let projection = Projection(coordinates: coordinates)
        let points = coordinates.map(projection.project)

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }

            var furthestDistance = 0.0
            var furthestIndex = first
            for index in (first + 1)..<last {
                let distance = perpendicularDistance(points[index], from: points[first], to: points[last])
                if distance > furthestDistance {
                    furthestDistance = distance
                    furthestIndex = index
                }
            }

            if furthestDistance > tolerance {
                keep[furthestIndex] = true
                stack.append((first, furthestIndex))
                stack.append((furthestIndex, last))
            }
        }

        return zip(coordinates, keep).compactMap { $1 ? $0 : nil }
    }

    static func perpendicularDistance(
        _ point: PlanePoint,
        from start: PlanePoint,
        to end: PlanePoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        // Distance from the point to the infinite line through start and end.
        let cross = abs(dy * (point.x - start.x) - dx * (point.y - start.y))
        return cross / sqrt(lengthSquared)
    }

    // MARK: - Interpolation

    /// Centripetal Catmull–Rom (alpha = 0.5). The centripetal parameterisation
    /// is what keeps the curve from looping back on itself at sharp corners,
    /// which uniform Catmull–Rom does on switchbacks and street corners.
    static func catmullRom(
        _ coordinates: [CLLocationCoordinate2D],
        spacing: CLLocationDistance,
        maximumSamplesPerSegment: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 3 else { return coordinates }

        let projection = Projection(coordinates: coordinates)
        let points = removingConsecutiveDuplicates(coordinates.map(projection.project))
        guard points.count >= 3 else { return points.map(projection.unproject) }

        // Reflected phantom endpoints give the first and last real segments a
        // neighbour to bend towards, without a zero-length knot span.
        let leading = PlanePoint(
            x: 2 * points[0].x - points[1].x,
            y: 2 * points[0].y - points[1].y
        )
        let trailing = PlanePoint(
            x: 2 * points[points.count - 1].x - points[points.count - 2].x,
            y: 2 * points[points.count - 1].y - points[points.count - 2].y
        )
        let control = [leading] + points + [trailing]

        var output: [PlanePoint] = [points[0]]
        output.reserveCapacity(points.count * 4)

        // control[i] is points[i - 1]; the real segments run from i = 1 to
        // points.count - 1, each using the two points either side of it.
        for index in 1..<(control.count - 2) {
            let p0 = control[index - 1]
            let p1 = control[index]
            let p2 = control[index + 1]
            let p3 = control[index + 2]

            let t0 = 0.0
            let t1 = t0 + sqrt(distance(p0, p1))
            let t2 = t1 + sqrt(distance(p1, p2))
            let t3 = t2 + sqrt(distance(p2, p3))

            guard t1 > t0, t2 > t1, t3 > t2 else {
                output.append(p2)
                continue
            }

            let segmentLength = distance(p1, p2)
            let sampleCount = min(
                max(maximumSamplesPerSegment, 1),
                max(1, Int((segmentLength / max(spacing, 0.1)).rounded()))
            )

            for step in 1...sampleCount {
                let t = t1 + (t2 - t1) * Double(step) / Double(sampleCount)
                output.append(interpolate(p0, p1, p2, p3, t0: t0, t1: t1, t2: t2, t3: t3, t: t))
            }
        }

        return output.map(projection.unproject)
    }

    /// Barry–Goldman pyramidal evaluation of the Catmull–Rom segment p1…p2.
    private static func interpolate(
        _ p0: PlanePoint,
        _ p1: PlanePoint,
        _ p2: PlanePoint,
        _ p3: PlanePoint,
        t0: Double,
        t1: Double,
        t2: Double,
        t3: Double,
        t: Double
    ) -> PlanePoint {
        let a1 = mix(p0, p1, (t1 - t) / (t1 - t0), (t - t0) / (t1 - t0))
        let a2 = mix(p1, p2, (t2 - t) / (t2 - t1), (t - t1) / (t2 - t1))
        let a3 = mix(p2, p3, (t3 - t) / (t3 - t2), (t - t2) / (t3 - t2))
        let b1 = mix(a1, a2, (t2 - t) / (t2 - t0), (t - t0) / (t2 - t0))
        let b2 = mix(a2, a3, (t3 - t) / (t3 - t1), (t - t1) / (t3 - t1))
        return mix(b1, b2, (t2 - t) / (t2 - t1), (t - t1) / (t2 - t1))
    }

    private static func mix(
        _ lhs: PlanePoint,
        _ rhs: PlanePoint,
        _ lhsWeight: Double,
        _ rhsWeight: Double
    ) -> PlanePoint {
        PlanePoint(
            x: lhs.x * lhsWeight + rhs.x * rhsWeight,
            y: lhs.y * lhsWeight + rhs.y * rhsWeight
        )
    }

    private static func distance(_ lhs: PlanePoint, _ rhs: PlanePoint) -> Double {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }

    private static func removingConsecutiveDuplicates(_ points: [PlanePoint]) -> [PlanePoint] {
        var result: [PlanePoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            if let last = result.last, distance(last, point) < 0.01 { continue }
            result.append(point)
        }
        return result
    }

    /// Evenly thins an over-long coordinate list, always keeping both ends.
    static func decimate(
        _ coordinates: [CLLocationCoordinate2D],
        to limit: Int
    ) -> [CLLocationCoordinate2D] {
        guard limit > 2, coordinates.count > limit else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(limit - 1)
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(limit)
        for index in 0..<limit {
            result.append(coordinates[min(coordinates.count - 1, Int((Double(index) * step).rounded()))])
        }
        return result
    }
}
