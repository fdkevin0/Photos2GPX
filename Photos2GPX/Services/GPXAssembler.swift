import CoreLocation
import Foundation

/// Combines an optionally imported base document with freshly collected photo
/// waypoints and workout routes into the document that gets exported.
enum GPXAssembler {
    /// Photos taken more than this far apart are put in separate segments, so the
    /// synthesised photo track does not draw a straight line across a continent.
    static let photoTrackSegmentGap: TimeInterval = 4 * 60 * 60

    struct Input {
        var base: GPXDocument? = nil
        var photoWaypoints: [GPXPoint] = []
        var buildPhotoTrack = false
        var workoutTracks: [GPXTrack] = []
        var range: DateInterval? = nil
        var generatedAt = Date()
    }

    static func makeDocument(_ input: Input) -> GPXDocument {
        var document = GPXDocument()
        document.time = input.generatedAt
        document.name = title(for: input.range)
        document.desc = summaryDescription(for: input)
        document.keywords = "Photos2GPX"

        var waypoints = input.base?.waypoints ?? []
        waypoints.append(contentsOf: input.photoWaypoints)
        document.waypoints = deduplicate(waypoints).sorted(by: isOrderedBefore)

        var tracks = (input.base?.tracks ?? []).filter { !$0.isEmpty }
        tracks.append(contentsOf: input.workoutTracks.filter { !$0.isEmpty })

        if input.buildPhotoTrack {
            if let photoTrack = makePhotoTrack(from: input.photoWaypoints) {
                tracks.append(photoTrack)
            }
        }

        document.tracks = tracks.sorted { lhs, rhs in
            switch (lhs.startDate, rhs.startDate) {
            case let (left?, right?): left < right
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): (lhs.name ?? "") < (rhs.name ?? "")
            }
        }

        return document
    }

    /// Chains located photos into a track, splitting on long gaps.
    static func makePhotoTrack(from waypoints: [GPXPoint]) -> GPXTrack? {
        let ordered = waypoints
            .filter { $0.isValid && $0.timestamp != nil }
            .sorted(by: isOrderedBefore)
        guard ordered.count >= 2 else { return nil }

        var segments: [GPXTrackSegment] = []
        var current: [GPXPoint] = []
        var previousDate: Date?

        for waypoint in ordered {
            // Carry only geometry and time into the track; names and symbols
            // belong on the waypoint, not on every track point.
            let point = GPXPoint(
                latitude: waypoint.latitude,
                longitude: waypoint.longitude,
                elevation: waypoint.elevation,
                timestamp: waypoint.timestamp
            )
            if let previousDate, let date = waypoint.timestamp,
               date.timeIntervalSince(previousDate) > photoTrackSegmentGap {
                if current.count >= 2 { segments.append(GPXTrackSegment(points: current)) }
                current = []
            }
            current.append(point)
            previousDate = waypoint.timestamp
        }
        if current.count >= 2 { segments.append(GPXTrackSegment(points: current)) }

        guard !segments.isEmpty else { return nil }
        return GPXTrack(
            name: "Photo trail",
            desc: "Synthesised from \(ordered.count) geotagged photos",
            type: "photos",
            source: .photos,
            segments: segments
        )
    }

    /// Drops waypoints that describe the same fix at the same instant, which
    /// happens when the same base file is imported twice.
    static func deduplicate(_ waypoints: [GPXPoint]) -> [GPXPoint] {
        var seen = Set<String>()
        var result: [GPXPoint] = []
        result.reserveCapacity(waypoints.count)
        for waypoint in waypoints where waypoint.isValid {
            let latitude = (waypoint.latitude * 1_000_000).rounded()
            let longitude = (waypoint.longitude * 1_000_000).rounded()
            let time = waypoint.timestamp.map { $0.timeIntervalSince1970.rounded() } ?? -1
            let key = "\(latitude)|\(longitude)|\(time)|\(waypoint.name ?? "")"
            if seen.insert(key).inserted {
                result.append(waypoint)
            }
        }
        return result
    }

    static func isOrderedBefore(_ lhs: GPXPoint, _ rhs: GPXPoint) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (left?, right?): left < right
        case (nil, _?): false
        case (_?, nil): true
        case (nil, nil): false
        }
    }

    // MARK: - Naming

    static func title(for range: DateInterval?) -> String {
        guard let range else { return "Photos2GPX export" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let start = formatter.string(from: range.start)
        let end = formatter.string(from: range.end)
        return start == end ? "Photos2GPX – \(start)" : "Photos2GPX – \(start) to \(end)"
    }

    static func fileName(for range: DateInterval?) -> String {
        guard let range else { return "Photos2GPX.gpx" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: range.start)
        let end = formatter.string(from: range.end)
        return start == end
            ? "Photos2GPX-\(start).gpx"
            : "Photos2GPX-\(start)_to_\(end).gpx"
    }

    private static func summaryDescription(for input: Input) -> String {
        var parts: [String] = []
        if !input.photoWaypoints.isEmpty {
            parts.append("\(input.photoWaypoints.count) photo waypoints")
        }
        let workoutPoints = input.workoutTracks.reduce(0) { $0 + $1.pointCount }
        if workoutPoints > 0 {
            let trackCount = input.workoutTracks.filter { !$0.isEmpty }.count
            parts.append("\(trackCount) workout tracks (\(workoutPoints) points)")
        }
        if let base = input.base, !base.isEmpty {
            parts.append("merged with an imported GPX file")
        }
        guard !parts.isEmpty else { return "Exported by Photos2GPX" }
        return "Exported by Photos2GPX: " + parts.joined(separator: ", ")
    }
}
