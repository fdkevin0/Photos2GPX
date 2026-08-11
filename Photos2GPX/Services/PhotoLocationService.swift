import CoreLocation
import Foundation
import Photos

/// One geotagged asset found in the library.
struct PhotoRecord: Identifiable, Hashable, Sendable {
    /// `PHAsset.localIdentifier`, used to load a thumbnail on demand.
    let id: String
    let point: GPXPoint
    let isVideo: Bool

    var timestamp: Date? { point.timestamp }
    var name: String { point.name ?? id }
}

/// Result of a library scan, including the assets that had to be skipped so the
/// UI can explain why the export is smaller than the camera roll.
struct PhotoScanResult: Sendable {
    var records: [PhotoRecord] = []
    var totalAssets = 0

    var missingLocationCount: Int { max(0, totalAssets - records.count) }
    var waypoints: [GPXPoint] { records.map(\.point) }
}

enum PhotoLocationService {
    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    @discardableResult
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Fetches every image (and optionally video) created in the interval that
    /// carries a GPS fix, in chronological order.
    static func scan(range: DateInterval, includeVideos: Bool) async -> PhotoScanResult {
        await Task.detached(priority: .userInitiated) {
            fetch(range: range, includeVideos: includeVideos)
        }.value
    }

    private static func fetch(range: DateInterval, includeVideos: Bool) -> PhotoScanResult {
        let options = PHFetchOptions()
        let datePredicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            range.start as NSDate,
            range.end as NSDate
        )
        let typePredicate: NSPredicate = includeVideos
            ? NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, typePredicate])
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false

        let assets = PHAsset.fetchAssets(with: options)
        var result = PhotoScanResult()
        result.totalAssets = assets.count
        result.records.reserveCapacity(min(assets.count, 4096))

        assets.enumerateObjects { asset, _, _ in
            guard let location = asset.location, var point = GPXPoint(location: location) else { return }
            point.timestamp = asset.creationDate ?? location.timestamp
            point.name = displayName(for: asset)
            point.desc = assetDescription(for: asset, location: location)
            point.symbol = asset.mediaType == .video ? "Video" : "Camera"
            point.type = asset.mediaType == .video ? "video" : "photo"
            // Speed/course from an asset's location fix is not meaningful.
            point.speed = nil
            point.course = nil
            result.records.append(
                PhotoRecord(id: asset.localIdentifier, point: point, isVideo: asset.mediaType == .video)
            )
        }
        return result
    }

    private static func displayName(for asset: PHAsset) -> String {
        if let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename,
           !filename.isEmpty {
            return filename
        }
        if let date = asset.creationDate {
            return timestampNameFormatter.string(from: date)
        }
        return asset.localIdentifier
    }

    private static func assetDescription(for asset: PHAsset, location: CLLocation) -> String {
        var parts: [String] = [asset.mediaType == .video ? "Video" : "Photo"]
        if let date = asset.creationDate {
            parts.append(descriptionDateFormatter.string(from: date))
        }
        if asset.mediaType == .video, asset.duration > 0 {
            parts.append(String(format: "%.0fs", asset.duration))
        }
        if location.horizontalAccuracy > 0 {
            parts.append(String(format: "±%.0f m", location.horizontalAccuracy))
        }
        return parts.joined(separator: " · ")
    }

    private static let timestampNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let descriptionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

extension PHAuthorizationStatus {
    var isReadable: Bool {
        self == .authorized || self == .limited
    }

    var explanation: String {
        switch self {
        case .notDetermined: "Photos2GPX has not asked for photo access yet."
        case .restricted: "Photo access is restricted on this device."
        case .denied: "Photo access was denied. Enable it in Settings › Privacy › Photos."
        case .authorized: "Full photo library access granted."
        case .limited: "Only the photos you selected are visible to Photos2GPX."
        @unknown default: "Unknown photo authorization status."
        }
    }
}
