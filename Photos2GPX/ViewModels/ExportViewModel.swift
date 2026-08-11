import Foundation
import HealthKit
import Observation
import Photos
import SwiftUI

@Observable
@MainActor
final class ExportViewModel {
    // MARK: - Inputs

    var startDate: Date
    var endDate: Date
    var includePhotos = true
    var includeVideos = true
    var buildPhotoTrack = true
    var includeWorkouts = true

    /// Base document the user imported; its waypoints and tracks are merged into
    /// every export until it is removed.
    private(set) var baseDocument: GPXDocument?
    private(set) var baseFileName: String?

    // MARK: - Outputs

    private(set) var photoScan: PhotoScanResult?
    private(set) var workoutRecords: [WorkoutRecord] = []
    private(set) var document: GPXDocument?
    private(set) var exportURL: URL?
    private(set) var warnings: [String] = []
    private(set) var isCollecting = false
    private(set) var progressMessage: String?
    var errorMessage: String?

    var photoAuthorization: PHAuthorizationStatus = PhotoLocationService.authorizationStatus

    private let workoutService = WorkoutRouteService()

    init(now: Date = Date()) {
        let interval = DateRangePreset.last7Days.interval(now: now)
        startDate = interval.start
        endDate = interval.end
    }

    // MARK: - Derived state

    var range: DateInterval? {
        guard endDate >= startDate else { return nil }
        return DateInterval(start: startDate, end: endDate)
    }

    var isRangeValid: Bool { range != nil }

    var canCollect: Bool {
        isRangeValid && !isCollecting && (includePhotos || includeWorkouts || baseDocument != nil)
    }

    var isHealthAvailable: Bool { WorkoutRouteService.isAvailable }

    var photoCount: Int { photoScan?.records.count ?? 0 }

    var workoutsWithRouteCount: Int { workoutRecords.filter(\.hasRoute).count }

    var suggestedFileName: String { GPXAssembler.fileName(for: range) }

    var hasResult: Bool { document.map { !$0.isEmpty } ?? false }

    // MARK: - Actions

    func apply(preset: DateRangePreset) {
        let interval = preset.interval()
        startDate = interval.start
        endDate = interval.end
        invalidateResult()
    }

    func inputsChanged() {
        invalidateResult()
    }

    func importBase(from result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            importBase(from: url)
        }
    }

    func importBase(from url: URL) {
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsScopedAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try GPXParser().parse(data: data)
            baseDocument = parsed
            baseFileName = url.lastPathComponent
            invalidateResult()
        } catch {
            errorMessage = "Could not import \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    func removeBase() {
        baseDocument = nil
        baseFileName = nil
        invalidateResult()
    }

    func collect() async {
        guard let range else {
            errorMessage = "The end date must not be earlier than the start date."
            return
        }

        isCollecting = true
        warnings = []
        errorMessage = nil
        defer {
            isCollecting = false
            progressMessage = nil
        }

        var scan: PhotoScanResult?
        if includePhotos {
            progressMessage = "Reading photo library…"
            var status = photoAuthorization
            if !status.isReadable {
                status = await PhotoLocationService.requestAuthorization()
                photoAuthorization = status
            }
            if status.isReadable {
                scan = await PhotoLocationService.scan(range: range, includeVideos: includeVideos)
                if let scan {
                    if scan.totalAssets == 0 {
                        warnings.append("No photos or videos were created in this time range.")
                    } else if scan.records.isEmpty {
                        warnings.append("\(scan.totalAssets) items found, but none of them are geotagged.")
                    } else if scan.missingLocationCount > 0 {
                        warnings.append("\(scan.missingLocationCount) of \(scan.totalAssets) items had no GPS data and were skipped.")
                    }
                    if status == .limited {
                        warnings.append("Only the photos you granted access to were searched.")
                    }
                }
            } else {
                warnings.append(status.explanation)
            }
        }
        photoScan = scan

        var workouts: [WorkoutRecord] = []
        if includeWorkouts {
            progressMessage = "Reading workouts…"
            if WorkoutRouteService.isAvailable {
                do {
                    try await workoutService.requestAuthorization()
                    workouts = try await workoutService.fetchWorkouts(in: range)
                    if workouts.isEmpty {
                        warnings.append("No workouts were recorded in this time range.")
                    } else {
                        let withoutRoute = workouts.filter { !$0.hasRoute }.count
                        if withoutRoute > 0 {
                            warnings.append("\(withoutRoute) of \(workouts.count) workouts have no GPS route (indoor or route access not granted).")
                        }
                    }
                } catch {
                    warnings.append("Workouts could not be read: \(error.localizedDescription)")
                }
            } else {
                warnings.append(WorkoutServiceError.healthDataUnavailable.localizedDescription)
            }
        }
        workoutRecords = workouts

        progressMessage = "Building GPX…"
        let assembled = GPXAssembler.makeDocument(
            GPXAssembler.Input(
                base: baseDocument,
                photoWaypoints: scan?.waypoints ?? [],
                buildPhotoTrack: buildPhotoTrack,
                workoutTracks: workouts.map(\.track),
                range: range
            )
        )

        guard !assembled.isEmpty else {
            document = nil
            exportURL = nil
            errorMessage = "Nothing to export — no geotagged photos, workout routes or imported data in this range."
            return
        }

        document = assembled
        do {
            exportURL = try writeTemporaryFile(for: assembled)
        } catch {
            exportURL = nil
            warnings.append("The GPX could not be staged for sharing: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func invalidateResult() {
        document = nil
        photoScan = nil
        workoutRecords = []
        if let exportURL {
            try? FileManager.default.removeItem(at: exportURL)
        }
        exportURL = nil
        warnings = []
    }

    private func writeTemporaryFile(for document: GPXDocument) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photos2GPX", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Clear stale exports so the share sheet never offers an old file.
        if let existing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in existing {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let url = directory.appendingPathComponent(GPXAssembler.fileName(for: range))
        try GPXWriter.data(from: document).write(to: url, options: .atomic)
        return url
    }
}
