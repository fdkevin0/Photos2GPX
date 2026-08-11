import CoreLocation
import Foundation
import MapKit

/// One drawable stroke: a stretch of a track that shares a transport mode.
struct RenderedPolyline: Identifiable, @unchecked Sendable {
    let id = UUID()
    let trackID: UUID
    /// Activity segment this stroke was cut from, for selection and highlighting.
    let segmentID: UUID?
    let trackName: String?
    let source: GPXSource
    let mode: TransportMode
    /// Densely interpolated coordinates that read as a curve.
    let coordinates: [CLLocationCoordinate2D]
    /// The untouched fixes, for the "show raw trace" overlay.
    let rawCoordinates: [CLLocationCoordinate2D]
}

struct RenderedWaypoint: Identifiable, @unchecked Sendable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let name: String
}

struct RenderedEndpoint: Identifiable, @unchecked Sendable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let isStart: Bool
}

/// Everything the map views need, prepared once off the main actor.
struct TrackRenderModel: @unchecked Sendable {
    var polylines: [RenderedPolyline] = []
    var waypoints: [RenderedWaypoint] = []
    var endpoints: [RenderedEndpoint] = []
    var segments: [ActivitySegment] = []
    var region: MKCoordinateRegion?
    /// Sampled waypoints omitted from `waypoints` to keep the map responsive.
    var hiddenWaypointCount = 0

    var isEmpty: Bool { polylines.isEmpty && waypoints.isEmpty }

    /// Modes actually present, in `TransportMode.allCases` order, for the legend.
    var modesPresent: [TransportMode] {
        let present = Set(segments.map(\.mode))
        return TransportMode.allCases.filter(present.contains)
    }

    func totalDistance(for mode: TransportMode) -> CLLocationDistance {
        segments.filter { $0.mode == mode }.reduce(0) { $0 + $1.distance }
    }

    func totalDuration(for mode: TransportMode) -> TimeInterval {
        segments.filter { $0.mode == mode }.reduce(0) { $0 + $1.duration }
    }
}

enum TrackRenderer {
    /// Classifies and smooths a document. Runs off the main actor because a long
    /// day of tracks is tens of thousands of points.
    static func prepare(
        document: GPXDocument,
        smoothing: TrackSmoother.Options = .default,
        maximumWaypoints: Int = 300
    ) async -> TrackRenderModel {
        await Task.detached(priority: .userInitiated) {
            build(document: document, smoothing: smoothing, maximumWaypoints: maximumWaypoints)
        }.value
    }

    static func build(
        document: GPXDocument,
        smoothing: TrackSmoother.Options = .default,
        maximumWaypoints: Int = 300
    ) -> TrackRenderModel {
        var model = TrackRenderModel()

        for track in document.tracks where !track.isEmpty {
            let segments = ActivityClassifier.segments(for: track)
            model.segments.append(contentsOf: segments)

            for segment in segments where segment.points.count >= 2 {
                let raw = segment.coordinates
                model.polylines.append(
                    RenderedPolyline(
                        trackID: track.id,
                        segmentID: segment.id,
                        trackName: track.name,
                        source: track.source,
                        mode: segment.mode,
                        coordinates: TrackSmoother.smooth(raw, options: smoothing),
                        rawCoordinates: raw
                    )
                )
            }

            // A track whose points carry no usable timing produces no activity
            // segments; draw it anyway, unclassified.
            if segments.isEmpty {
                for gpxSegment in track.segments where gpxSegment.points.count >= 2 {
                    let raw = gpxSegment.points.map(\.coordinate)
                    model.polylines.append(
                        RenderedPolyline(
                            trackID: track.id,
                            segmentID: nil,
                            trackName: track.name,
                            source: track.source,
                            mode: .unknown,
                            coordinates: TrackSmoother.smooth(raw, options: smoothing),
                            rawCoordinates: raw
                        )
                    )
                }
            }

            if let first = track.segments.first?.points.first,
               let last = track.segments.last?.points.last {
                model.endpoints.append(RenderedEndpoint(coordinate: first.coordinate, isStart: true))
                model.endpoints.append(RenderedEndpoint(coordinate: last.coordinate, isStart: false))
            }
        }

        model.segments.sort { lhs, rhs in
            switch (lhs.start, rhs.start) {
            case let (left?, right?): return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }

        let allWaypoints = document.waypoints.filter(\.isValid)
        let step = max(1, allWaypoints.count / max(1, maximumWaypoints))
        model.waypoints = allWaypoints.enumerated()
            .filter { $0.offset % step == 0 }
            .map {
                RenderedWaypoint(
                    id: $0.offset,
                    coordinate: $0.element.coordinate,
                    name: $0.element.name ?? ""
                )
            }
        model.hiddenWaypointCount = allWaypoints.count - model.waypoints.count

        model.region = region(for: document.allCoordinates)
        return model
    }

    /// Bounding region with a little padding, or `nil` when there is nothing to
    /// show.
    static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }

        var minLatitude = 90.0
        var maxLatitude = -90.0
        var minLongitude = 180.0
        var maxLongitude = -180.0
        var found = false

        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            found = true
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        guard found else { return nil }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.3, 0.004),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.3, 0.004)
            )
        )
    }
}
