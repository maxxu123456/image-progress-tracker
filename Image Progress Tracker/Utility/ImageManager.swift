import UIKit
import Photos
import ImageIO
import SwiftUI

enum ImageStore {
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    static let documentsDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    static let placeholder: UIImage = UIImage(systemName: "photo") ?? UIImage()

    /// Saves a UIImage as JPEG to the Documents directory, embedding metadata if provided.
    /// Returns the filename (UUID string) on success, or nil on failure.
    static func saveJPEG(_ image: UIImage, metadata: [String: Any]? = nil, compressionQuality: CGFloat = 0.5) -> String? {
        let filename = UUID().uuidString
        let url = documentsDirectory.appendingPathComponent(filename)

        if let metadata = metadata {
            guard let cgImage = image.cgImage,
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
                return nil
            }
            var options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: compressionQuality
            ]
            for (key, value) in metadata {
                options[key as CFString] = value
            }
            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            return filename
        } else {
            guard let data = image.jpegData(compressionQuality: compressionQuality) else {
                return nil
            }
            do {
                try data.write(to: url)
                return filename
            } catch {
                return nil
            }
        }
    }

    /// Returns true if the image file exists on disk.
    static func imageExists(filename: String) -> Bool {
        let url = documentsDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Loads an image from the Documents directory by filename.
    /// Returns a placeholder if the file is missing or corrupted.
    static func loadImage(filename: String) -> UIImage {
        let url = documentsDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let image = UIImage(data: data) else {
            return placeholder
        }
        return image
    }

    /// Loads the raw JPEG data from the Documents directory by filename.
    static func loadImageData(filename: String) -> Data? {
        let url = documentsDirectory.appendingPathComponent(filename)
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Generates a cached downsampled image of the given max dimension, loading from disk off-main.
    static func loadThumbnail(filename: String, maxDimension: CGFloat) async -> UIImage {
        let key = cacheKey(filename: filename, maxDimension: maxDimension)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        let image = await Task.detached(priority: .userInitiated, operation: {
            loadDownsampledImage(filename: filename, maxDimension: maxDimension) ?? placeholder
        }).value
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Deletes an image file from the Documents directory.
    static func deleteImage(filename: String) {
        let url = documentsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        imageCache.removeAllObjects()
    }

    private static func cacheKey(filename: String, maxDimension: CGFloat) -> NSString {
        "\(filename)-\(Int(maxDimension.rounded(.up)))" as NSString
    }

    private static func loadDownsampledImage(filename: String, maxDimension: CGFloat) -> UIImage? {
        let url = documentsDirectory.appendingPathComponent(filename)
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxDimension.rounded(.up)))
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Async Thumbnail View

/// A SwiftUI view that loads a thumbnail asynchronously and shows a placeholder while loading.
struct AsyncThumbnail: View {
    let filename: String
    let maxDimension: CGFloat
    @State private var image: UIImage?

    private var taskID: String {
        "\(filename)-\(Int(maxDimension.rounded(.up)))"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemFill))

            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: taskID) {
            image = nil
            let loadedImage = await ImageStore.loadThumbnail(filename: filename, maxDimension: maxDimension)
            guard !Task.isCancelled else { return }
            image = loadedImage
        }
    }
}

// MARK: - Photo Library Export

final class ImageSaver: NSObject {
    /// Saves the original JPEG data (with embedded EXIF) to the photo library,
    /// setting the asset's creation date to the provided date.
    /// Will refuse to export if the source file is missing (prevents saving placeholder).
    func saveToPhotoLibrary(filename: String, creationDate: Date, completion: ((Bool) -> Void)? = nil) {
        guard ImageStore.imageExists(filename: filename) else {
            DispatchQueue.main.async { completion?(false) }
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let data = ImageStore.loadImageData(filename: filename) {
                    request.addResource(with: .photo, data: data, options: nil)
                }
                request.creationDate = creationDate
            } completionHandler: { success, _ in
                DispatchQueue.main.async { completion?(success) }
            }
        }
    }
}
