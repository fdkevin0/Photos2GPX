import MapKit
import SwiftUI

struct MapPolylineItem: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let source: GPXSource
}

struct MapWaypointItem: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
}

/// Read-only map showing every track segment and a capped number of waypoints.
struct MapPreview: View {
    let polylines: [MapPolylineItem]
    let waypoints: [MapWaypointItem]

    @State private var position: MapCameraPosition

    init(document: GPXDocument, maximumWaypoints: Int = 300) {
        var lines: [MapPolylineItem] = []
        for track in document.tracks {
            for segment in track.segments where segment.points.count >= 2 {
                lines.append(
                    MapPolylineItem(
                        id: segment.id,
                        coordinates: segment.points.map(\.coordinate),
                        source: track.source
                    )
                )
            }
        }
        polylines = lines

        // Drawing thousands of annotations makes the preview unusable, so a
        // representative sample is shown instead.
        let allWaypoints = document.waypoints
        let step = max(1, allWaypoints.count / max(1, maximumWaypoints))
        waypoints = allWaypoints.enumerated()
            .filter { $0.offset % step == 0 }
            .map { MapWaypointItem(id: $0.offset, coordinate: $0.element.coordinate) }

        if let region = MapPreview.region(for: document.allCoordinates) {
            _position = State(initialValue: MapCameraPosition.region(region))
        } else {
            _position = State(initialValue: MapCameraPosition.automatic)
        }
    }

    var body: some View {
        Map(position: $position) {
            ForEach(polylines) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(
                        MapPreview.color(for: line.source),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
            }
            ForEach(waypoints) { waypoint in
                Annotation(coordinate: waypoint.coordinate) {
                    Circle()
                        .fill(MapPreview.color(for: .photos))
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                } label: {
                    EmptyView()
                }
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    static func color(for source: GPXSource) -> Color {
        switch source {
        case .workout: .blue
        case .photos: .orange
        case .imported: .green
        }
    }

    /// Bounding region with a little padding, or `nil` when there is nothing to show.
    static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }

        var minLatitude = 90.0
        var maxLatitude = -90.0
        var minLongitude = 180.0
        var maxLongitude = -180.0

        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        guard minLatitude <= maxLatitude, minLongitude <= maxLongitude else { return nil }

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLatitude - minLatitude) * 1.3, 0.005),
            longitudeDelta: max((maxLongitude - minLongitude) * 1.3, 0.005)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
