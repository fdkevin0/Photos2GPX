import MapKit
import SwiftUI
import UIKit

/// How a stroke on the map picks its colour.
enum TrackColorMode: String, CaseIterable, Identifiable {
    case activity
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .source: return "Source"
        }
    }
}

/// Small non-interactive map card. Curves and activity colours, no gestures —
/// it lives inside a scrolling list, so it must not eat drags.
struct MapPreview: View {
    let document: GPXDocument
    var colorBy: TrackColorMode = .activity

    @State private var model: TrackRenderModel?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position, interactionModes: []) {
            if let model {
                ForEach(model.polylines) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(
                            TrackStyle.color(for: line, mode: colorBy),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                        )
                }
                ForEach(model.waypoints) { waypoint in
                    Annotation(coordinate: waypoint.coordinate) {
                        TrackStyle.waypointDot
                    } label: {
                        EmptyView()
                    }
                }
            }
        }
        .overlay {
            if model == nil {
                ProgressView()
            }
        }
        .task(id: document) {
            let prepared = await TrackRenderer.prepare(document: document)
            model = prepared
            if let region = prepared.region {
                position = .region(region)
            }
        }
    }
}

/// Shared drawing constants so the inline preview and the full map agree.
enum TrackStyle {
    static let lineWidth: CGFloat = 4.5
    static let selectedLineWidth: CGFloat = 7
    static let casingWidth: CGFloat = 2.5

    static func color(for line: RenderedPolyline, mode: TrackColorMode) -> Color {
        switch mode {
        case .activity: return line.mode.color
        case .source: return line.source.color
        }
    }

    /// Drawn under each stroke so routes stay readable over busy map tiles.
    static var casingColor: Color {
        Color(uiColor: .systemBackground).opacity(0.85)
    }

    static var waypointDot: some View {
        Circle()
            .fill(GPXSource.photos.color)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: 10, height: 10)
    }
}
