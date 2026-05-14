import SwiftUI
import ImageIO
import UIKit

/// In-memory cache of decoded UIImages keyed by URL + target pixel size.
/// Backs `RemoteImage` so reopening a detail sheet re-uses already-decoded
/// thumbnails instead of round-tripping Yelp + re-decoding full-res JPEGs.
final actor RemoteImageCache {
    static let shared = RemoteImageCache()

    private var cache: [String: UIImage] = [:]
    private var order: [String] = []
    private let maxCount = 80

    func image(for url: URL, targetSize: CGSize, scale: CGFloat) async -> UIImage? {
        let key = Self.key(url: url, targetSize: targetSize, scale: scale)
        if let cached = cache[key] {
            return cached
        }
        guard let image = await Self.fetchAndDownsample(url: url, targetSize: targetSize, scale: scale) else {
            return nil
        }
        cache[key] = image
        order.append(key)
        if order.count > maxCount, let evict = order.first {
            order.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return image
    }

    private static func key(url: URL, targetSize: CGSize, scale: CGFloat) -> String {
        "\(url.absoluteString)|\(Int(targetSize.width))x\(Int(targetSize.height))@\(scale)"
    }

    private static func fetchAndDownsample(url: URL, targetSize: CGSize, scale: CGFloat) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return downsample(data: data, to: targetSize, scale: scale)
        } catch {
            return nil
        }
    }

    private static func downsample(data: Data, to size: CGSize, scale: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let maxDimensionInPixels = max(size.width, size.height) * scale
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

/// Drop-in replacement for `AsyncImage` that downsamples to a fixed target
/// size and caches the decoded result. Use when the rendered size is known
/// up-front and source images may be much larger than the display.
struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let targetSize: CGSize
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            let scale = await MainActor.run { UIScreen.main.scale }
            let loaded = await RemoteImageCache.shared.image(for: url, targetSize: targetSize, scale: scale)
            if !Task.isCancelled {
                image = loaded
            }
        }
    }
}
