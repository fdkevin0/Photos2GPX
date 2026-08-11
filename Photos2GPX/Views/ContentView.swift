import Photos
import SwiftUI

struct ContentView: View {
    @State private var model = ExportViewModel()
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Form {
                rangeSection
                sourcesSection
                baseSection
                collectSection
                resultSection
                warningsSection
            }
            .navigationTitle("Photos2GPX")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.gpx, .xml],
                allowsMultipleSelection: false
            ) { result in
                model.importBase(from: result)
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                ),
                actions: {
                    Button("OK", role: .cancel) { model.errorMessage = nil }
                },
                message: {
                    Text(model.errorMessage ?? "")
                }
            )
        }
    }

    // MARK: - Sections

    private var rangeSection: some View {
        Section {
            DatePicker("From", selection: $model.startDate, displayedComponents: [.date, .hourAndMinute])
                .onChange(of: model.startDate) { model.inputsChanged() }
            DatePicker("To", selection: $model.endDate, displayedComponents: [.date, .hourAndMinute])
                .onChange(of: model.endDate) { model.inputsChanged() }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DateRangePreset.allCases) { preset in
                        Button(preset.title) {
                            model.apply(preset: preset)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))

            if !model.isRangeValid {
                Label("The end date is before the start date.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        } header: {
            Text("Time range")
        } footer: {
            Text("Photos and workouts inside this window are collected.")
        }
    }

    private var sourcesSection: some View {
        Section("Sources") {
            Toggle("Photos", isOn: $model.includePhotos)
                .onChange(of: model.includePhotos) { model.inputsChanged() }
            if model.includePhotos {
                Toggle("Include videos", isOn: $model.includeVideos)
                    .onChange(of: model.includeVideos) { model.inputsChanged() }
                Toggle("Connect photos into a track", isOn: $model.buildPhotoTrack)
                    .onChange(of: model.buildPhotoTrack) { model.inputsChanged() }
                if !model.photoAuthorization.isReadable {
                    Text(model.photoAuthorization.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Health workouts", isOn: $model.includeWorkouts)
                .disabled(!model.isHealthAvailable)
                .onChange(of: model.includeWorkouts) { model.inputsChanged() }
            if !model.isHealthAvailable {
                Text("Health data is not available on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var baseSection: some View {
        Section {
            if let name = model.baseFileName, let base = model.baseDocument {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.body)
                    Text("\(base.waypoints.count) waypoints · \(base.tracks.count) tracks · \(base.trackPointCount) track points")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Remove imported file", role: .destructive) {
                    model.removeBase()
                }
            } else {
                Button {
                    isImporting = true
                } label: {
                    Label("Import GPX as starting point", systemImage: "square.and.arrow.down")
                }
            }
        } header: {
            Text("Starting file")
        } footer: {
            Text("Optional. Waypoints and tracks from the imported file are merged into the export.")
        }
    }

    private var collectSection: some View {
        Section {
            Button {
                Task { await model.collect() }
            } label: {
                HStack {
                    if model.isCollecting {
                        ProgressView()
                            .padding(.trailing, 4)
                    }
                    Text(model.isCollecting ? (model.progressMessage ?? "Working…") : "Collect data")
                }
            }
            .disabled(!model.canCollect)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let document = model.document, model.hasResult {
            Section("Result") {
                LabeledContent("Waypoints", value: "\(document.waypoints.count)")
                LabeledContent("Tracks", value: "\(document.tracks.count)")
                LabeledContent("Track points", value: "\(document.trackPointCount)")
                LabeledContent("Distance", value: Formatters.distance(document.totalDistance))

                NavigationLink {
                    ResultView(document: document, exportURL: model.exportURL, fileName: model.suggestedFileName)
                } label: {
                    Label("Preview & export", systemImage: "map")
                }

                if let url = model.exportURL {
                    ShareLink(item: url) {
                        Label("Share GPX", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if !model.workoutRecords.isEmpty || model.photoCount > 0 {
                Section("Collected") {
                    if model.photoCount > 0 {
                        NavigationLink {
                            PhotoListView(records: model.photoScan?.records ?? [])
                        } label: {
                            LabeledContent("Geotagged photos", value: "\(model.photoCount)")
                        }
                    }
                    if !model.workoutRecords.isEmpty {
                        NavigationLink {
                            WorkoutListView(records: model.workoutRecords)
                        } label: {
                            LabeledContent(
                                "Workouts with GPS",
                                value: "\(model.workoutsWithRouteCount) of \(model.workoutRecords.count)"
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        if !model.warnings.isEmpty {
            Section("Notes") {
                // Indexed because two sources can produce the same message.
                ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
