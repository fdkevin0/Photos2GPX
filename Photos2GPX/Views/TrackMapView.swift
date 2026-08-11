import MapKit
import SwiftUI

/// Full-screen map of a GPX document: smoothed routes coloured by the transport
/// mode inferred from speed, with a legend and a tappable activity timeline.
struct TrackMapView: View {
    let document: GPXDocument

    @State private var model: TrackRenderModel?
    @State private var position: MapCameraPosition = .automatic
    @State private var colorBy: TrackColorMode = .activity
    @State private var showRawTrace = false
    @State private var showWaypoints = true
    @State private var useSatellite = false
    @State private var selectedSegmentID: UUID?
    @State private var showBreakdown = false

    var body: some View {
        Map(position: $position) {
            mapContent
        }
        .mapStyle(useSatellite ? MapStyle.hybrid(elevation: .realistic) : MapStyle.standard(elevation: .flat))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay {
            if model == nil {
                ProgressView("Analysing route…")
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let model, !model.segments.isEmpty {
                bottomPanel(for: model)
            }
        }
        .navigationTitle("Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                optionsMenu
            }
        }
        .navigationDestination(isPresented: $showBreakdown) {
            ActivityBreakdownView(segments: model?.segments ?? [])
        }
        .task(id: document) {
            let prepared = await TrackRenderer.prepare(document: document)
            model = prepared
            if let region = prepared.region {
                position = .region(region)
            }
        }
    }

    // MARK: - Map content

    @MapContentBuilder
    private var mapContent: some MapContent {
        if let model {
            if showRawTrace {
                ForEach(model.polylines) { line in
                    MapPolyline(coordinates: line.rawCoordinates)
                        .stroke(
                            Color.gray.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                        )
                }
            }

            // Casing pass first so every stroke sits on the same backing.
            ForEach(model.polylines) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(
                        TrackStyle.casingColor,
                        style: StrokeStyle(
                            lineWidth: width(for: line) + TrackStyle.casingWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }

            ForEach(model.polylines) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(
                        TrackStyle.color(for: line, mode: colorBy)
                            .opacity(isDimmed(line) ? 0.35 : 1),
                        style: StrokeStyle(
                            lineWidth: width(for: line),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }

            if showWaypoints {
                ForEach(model.waypoints) { waypoint in
                    Annotation(coordinate: waypoint.coordinate) {
                        TrackStyle.waypointDot
                    } label: {
                        EmptyView()
                    }
                }
            }

            ForEach(model.endpoints) { endpoint in
                Annotation(coordinate: endpoint.coordinate) {
                    Image(systemName: endpoint.isStart ? "flag.circle.fill" : "flag.checkered.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(endpoint.isStart ? Color.green : Color.red, Color.white)
                } label: {
                    EmptyView()
                }
            }
        }
    }

    private func width(for line: RenderedPolyline) -> CGFloat {
        guard let selectedSegmentID else { return TrackStyle.lineWidth }
        return line.segmentID == selectedSegmentID ? TrackStyle.selectedLineWidth : TrackStyle.lineWidth
    }

    private func isDimmed(_ line: RenderedPolyline) -> Bool {
        guard let selectedSegmentID else { return false }
        return line.segmentID != selectedSegmentID
    }

    // MARK: - Controls

    private var optionsMenu: some View {
        Menu {
            Picker("Colour by", selection: $colorBy) {
                ForEach(TrackColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Toggle("Show raw fixes", isOn: $showRawTrace)
            Toggle("Show photo waypoints", isOn: $showWaypoints)
            Toggle("Satellite", isOn: $useSatellite)

            if let model, !model.segments.isEmpty {
                Divider()
                // A NavigationLink inside a Menu never pushes, so the menu only
                // flips a flag and the destination is declared on the view.
                Button {
                    showBreakdown = true
                } label: {
                    Label("Activity breakdown", systemImage: "list.bullet.rectangle")
                }
            }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Bottom panel

    private func bottomPanel(for model: TrackRenderModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            legend(for: model)
            timeline(for: model)
        }
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private func legend(for model: TrackRenderModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(model.modesPresent) { mode in
                    HStack(spacing: 5) {
                        Capsule()
                            .fill(mode.color)
                            .frame(width: 14, height: 4)
                        Image(systemName: mode.symbolName)
                            .font(.caption2)
                        Text(Formatters.distance(model.totalDistance(for: mode)))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func timeline(for model: TrackRenderModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.segments) { segment in
                    Button {
                        select(segment)
                    } label: {
                        SegmentChip(
                            segment: segment,
                            isSelected: selectedSegmentID == segment.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func select(_ segment: ActivitySegment) {
        if selectedSegmentID == segment.id {
            selectedSegmentID = nil
            if let region = model?.region {
                withAnimation { position = .region(region) }
            }
            return
        }
        selectedSegmentID = segment.id
        if let region = TrackRenderer.region(for: segment.coordinates) {
            withAnimation { position = .region(region) }
        }
    }
}

/// One tappable stop on the activity timeline.
private struct SegmentChip: View {
    let segment: ActivitySegment
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: segment.mode.symbolName)
                Text(segment.mode.displayName)
                    .fontWeight(.medium)
            }
            .font(.caption)
            .foregroundStyle(segment.mode.color)

            Text(Formatters.distance(segment.distance))
                .font(.caption2)
                .monospacedDigit()
            if let start = segment.start {
                Text(Formatters.timeOnly(start))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(segment.mode.color.opacity(isSelected ? 0.28 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(segment.mode.color.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
        )
    }
}

/// Per-segment detail, including how much the classifier trusts each label.
struct ActivityBreakdownView: View {
    let segments: [ActivitySegment]

    var body: some View {
        List {
            Section {
                ForEach(segments) { segment in
                    row(for: segment)
                }
            } footer: {
                Text("Modes are inferred from speed unless a segment came from a recorded workout. A car and a train at the same speed look the same to GPS, so treat low-confidence labels as a guess.")
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for segment: ActivitySegment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(segment.mode.displayName, systemImage: segment.mode.symbolName)
                    .font(.headline)
                    .foregroundStyle(segment.mode.color)
                Spacer()
                Text(segment.isInferred ? "estimated" : "recorded")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }

            if let start = segment.start, let end = segment.end {
                Text("\(Formatters.timeOnly(start)) – \(Formatters.timeOnly(end))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(Formatters.distance(segment.distance))
                Text(Formatters.duration(segment.duration))
                Text("avg \(Formatters.speed(segment.averageSpeed))")
                Text("peak \(Formatters.speed(segment.peakSpeed))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if segment.isInferred {
                HStack(spacing: 6) {
                    ProgressView(value: segment.confidence)
                        .progressViewStyle(.linear)
                        .tint(segment.mode.color)
                    Text("\(Int((segment.confidence * 100).rounded()))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
