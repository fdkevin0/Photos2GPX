import Photos
import SwiftUI
import UIKit

struct PhotoListView: View {
    let records: [PhotoRecord]

    var body: some View {
        List(records) { record in
            HStack(spacing: 12) {
                PhotoThumbnailView(assetIdentifier: record.id)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let timestamp = record.timestamp {
                        Text(Formatters.dateTime(timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(String(format: "%.5f, %.5f", record.point.latitude, record.point.longitude))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }

                Spacer(minLength: 0)

                if record.isVideo {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Geotagged photos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Loads a square thumbnail for a `PHAsset` on demand.
struct PhotoThumbnailView: View {
    let assetIdentifier: String

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: assetIdentifier) {
            image = await Self.loadThumbnail(identifier: assetIdentifier)
        }
    }

    private static func loadThumbnail(identifier: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        // `highQualityFormat` guarantees a single callback, so the continuation
        // below is always resumed exactly once.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 160, height: 160),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // Opportunistic delivery can call back twice; only the final
                // (non-degraded) result resumes the continuation.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
