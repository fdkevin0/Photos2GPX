import Foundation
import SwiftUI

/// Map preview plus the export actions for a finished document.
struct ResultView: View {
    let document: GPXDocument
    let exportURL: URL?
    let fileName: String

    @State private var isExporting = false
    @State private var exportFile: GPXFile?

    var body: some View {
        List {
            Section {
                MapPreview(document: document)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())

                NavigationLink {
                    TrackMapView(document: document)
                } label: {
                    Label("Open full map & activity", systemImage: "map")
                }
            }

            Section("Summary") {
                LabeledContent("Waypoints", value: "\(document.waypoints.count)")
                LabeledContent("Tracks", value: "\(document.tracks.count)")
                LabeledContent("Track points", value: "\(document.trackPointCount)")
                LabeledContent("Distance", value: Formatters.distance(document.totalDistance))
                if let range = document.dateRange {
                    LabeledContent("Covered", value: Formatters.range(range))
                }
            }

            if !document.tracks.isEmpty {
                Section("Tracks") {
                    ForEach(document.tracks) { track in
                        TrackRow(track: track)
                    }
                }
            }

            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share GPX", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    exportFile = GPXFile(data: GPXWriter.data(from: document))
                    isExporting = true
                } label: {
                    Label("Save to Files", systemImage: "folder")
                }
            } footer: {
                Text("File name: \(fileName)")
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportFile,
            contentType: .gpx,
            // The exporter appends the type's extension itself.
            defaultFilename: (fileName as NSString).deletingPathExtension
        ) { _ in }
    }
}

private struct TrackRow: View {
    let track: GPXTrack

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(track.source.color)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name ?? "Untitled track")
                    .font(.body)
                if let desc = track.desc, !desc.isEmpty {
                    Text(desc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("\(track.pointCount) points · \(Formatters.distance(track.distance))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
    }
}
