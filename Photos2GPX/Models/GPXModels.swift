import CoreLocation
import Foundation

/// Where a piece of geometry came from. Drives grouping and colouring in the UI.
enum GPXSource: String, Hashable, Sendable, CaseIterable {
    case imported
    case workout
    case photos

    var displayName: String {
        switch self {
        case .imported: "Imported"
        case .workout: "Workout"
        case .photos: "Photos"
        }
    }
}

/// A single geographic fix. Used both for `<wpt>` and for `<trkpt>` — the GPX
/// schema gives the two elements the same content model, so one type covers both.
struct GPXPoint: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var timestamp: Date?
    var name: String?
    var comment: String?
    var desc: String?
    var symbol: String?
    var type: String?
    /// Metres per second, written into a Garmin `TrackPointExtension` block.
    var speed: Double?
    /// Degrees from true north, written into a Garmin `TrackPointExtension` block.
    var course: Double?

    init(
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        timestamp: Date? = nil,
        name: String? = nil,
        comment: String? = nil,
        desc: String? = nil,
        symbol: String? = nil,
        type: String? = nil,
        speed: Double? = nil,
        course: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.timestamp = timestamp
        self.name = name
        self.comment = comment
        self.desc = desc
        self.symbol = symbol
        self.type = type
        self.speed = speed
        self.course = course
    }

    /// Builds a point from a Core Location fix, dropping the fields Core Location
    /// marks as unavailable (negative accuracies, negative speed/course).
    init?(location: CLLocation) {
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            elevation: location.verticalAccuracy > 0 ? location.altitude : nil,
            timestamp: location.timestamp,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }
}

/// One continuous run of points. A gap in recording starts a new segment.
struct GPXTrackSegment: Identifiable, Hashable, Sendable {
    var id = UUID()
    var points: [GPXPoint]

    init(id: UUID = UUID(), points: [GPXPoint] = []) {
        self.id = id
        self.points = points
    }
}

struct GPXTrack: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String?
    var desc: String?
    /// Free-form activity classification, e.g. `running` or `cycling`.
    var type: String?
    var source: GPXSource
    var segments: [GPXTrackSegment]

    init(
        id: UUID = UUID(),
        name: String? = nil,
        desc: String? = nil,
        type: String? = nil,
        source: GPXSource = .imported,
        segments: [GPXTrackSegment] = []
    ) {
        self.id = id
        self.name = name
        self.desc = desc
        self.type = type
        self.source = source
        self.segments = segments
    }

    var points: [GPXPoint] { segments.flatMap(\.points) }

    var pointCount: Int { segments.reduce(0) { $0 + $1.points.count } }

    var isEmpty: Bool { pointCount == 0 }

    var startDate: Date? { points.compactMap(\.timestamp).min() }

    var endDate: Date? { points.compactMap(\.timestamp).max() }

    /// Great-circle length in metres, summed segment by segment so that gaps
    /// between segments are not counted.
    var distance: CLLocationDistance {
        segments.reduce(0) { total, segment in
            total + GPXTrack.pathLength(of: segment.points)
        }
    }

    static func pathLength(of points: [GPXPoint]) -> CLLocationDistance {
        guard points.count > 1 else { return 0 }
        var total: CLLocationDistance = 0
        var previous = CLLocation(latitude: points[0].latitude, longitude: points[0].longitude)
        for point in points.dropFirst() {
            let current = CLLocation(latitude: point.latitude, longitude: point.longitude)
            total += current.distance(from: previous)
            previous = current
        }
        return total
    }
}

/// An in-memory GPX file: metadata, standalone waypoints and tracks.
struct GPXDocument: Hashable, Sendable {
    var name: String?
    var desc: String?
    var time: Date?
    var keywords: String?
    var waypoints: [GPXPoint]
    var tracks: [GPXTrack]

    init(
        name: String? = nil,
        desc: String? = nil,
        time: Date? = nil,
        keywords: String? = nil,
        waypoints: [GPXPoint] = [],
        tracks: [GPXTrack] = []
    ) {
        self.name = name
        self.desc = desc
        self.time = time
        self.keywords = keywords
        self.waypoints = waypoints
        self.tracks = tracks
    }

    var isEmpty: Bool { waypoints.isEmpty && tracks.allSatisfy(\.isEmpty) }

    var trackPointCount: Int { tracks.reduce(0) { $0 + $1.pointCount } }

    var totalDistance: CLLocationDistance { tracks.reduce(0) { $0 + $1.distance } }

    /// Earliest and latest timestamp across every point in the document.
    var dateRange: ClosedRange<Date>? {
        var dates = waypoints.compactMap(\.timestamp)
        for track in tracks {
            dates.append(contentsOf: track.points.compactMap(\.timestamp))
        }
        guard let min = dates.min(), let max = dates.max() else { return nil }
        return min...max
    }

    var allCoordinates: [CLLocationCoordinate2D] {
        var coordinates = waypoints.map(\.coordinate)
        for track in tracks {
            coordinates.append(contentsOf: track.points.map(\.coordinate))
        }
        return coordinates
    }
}
