import UIKit
import Photos
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ImageStore {
    enum Error: LocalizedError {
        case invalidImageData
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                return "The image data is invalid."
            case .writeFailed:
                return "The image could not be written to disk."
            }
        }
    }

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 128 * 1024 * 1024 // ~128 MB of decoded bitmap data
        return cache
    }()

    /// Decoded thumbnails are rounded up to one of these longest-side pixel
    /// sizes, so a handful of cache entries per photo serve every layout
    /// (grid cells, compare panes, full screen) on every display scale.
    ///
    /// 252/504/1008/2016/4032 are exact 1/2^k fractions of 12 MP (4032 px) and
    /// 48 MP (8064 px) photos: ImageIO's fast scaled JPEG decode only applies
    /// at or below original/2, which a 2048 bucket would just miss. The large
    /// sizes keep panoramas and long screenshots from falling back to a full
    /// decode, and the list is finite so deleteImage can evict every key.
    private static let pixelBuckets: [Int] = [
        128, 252, 384, 504, 768, 1008, 1536, 2016, 3072, 4032, 6144, 8064,
        12288, 16384, 24576, 32768, 49152, 65535
    ]

    static let documentsDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    static let placeholder: UIImage = UIImage(systemName: "photo") ?? UIImage()

    /// Encodes a camera capture as JPEG, embedding the capture metadata if provided.
    static func encodeJPEG(_ image: UIImage, metadata: [String: Any]? = nil, compressionQuality: CGFloat = 0.5) -> Data? {
        guard let metadata = metadata else {
            return image.jpegData(compressionQuality: compressionQuality)
        }
        let output = NSMutableData()
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
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
        return output as Data
    }

    /// Returns true if the image file exists on disk.
    static func imageExists(filename: String) -> Bool {
        let url = documentsDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Loads the raw image data from the Documents directory by filename.
    static func loadImageData(filename: String) -> Data? {
        let url = documentsDirectory.appendingPathComponent(filename)
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// True only for data ImageIO recognizes as an image with real pixel
    /// dimensions. (A bare CGImageSource is created for any bytes at all,
    /// including text, so its existence proves nothing.)
    static func isValidImageData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return false
        }
        return orientedPixelSize(of: source) != nil
    }

    /// Stricter check for photos crossing the app boundary in a collection
    /// file: only the formats the app itself stores (JPEG, HEIC/HEIF), sniffed
    /// before any deeper parse, so a hostile archive cannot route arbitrary
    /// bytes into less common ImageIO decoders.
    static func isTransferableImageData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif) else {
            return false
        }
        return orientedPixelSize(of: source) != nil
    }

    /// Saves raw image data to the Documents directory without recompressing it,
    /// so EXIF and other embedded metadata survive intact. Returns the filename.
    @discardableResult
    static func saveImageData(_ data: Data, filename: String = UUID().uuidString) throws -> String {
        guard isValidImageData(data) else {
            throw Error.invalidImageData
        }

        let url = documentsDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            throw Error.writeFailed
        }
    }

    // MARK: New photos

    /// A new photo ready to store: the bytes that will be written, a small
    /// preview for the form, and the EXIF capture date.
    struct PreparedPhoto: @unchecked Sendable {
        let data: Data
        let preview: UIImage
        let captureDate: Date?
    }

    /// JPEG and HEIC originals are kept byte-for-byte (no decode, no lossy
    /// re-encode, EXIF intact). Anything else (PNG, RAW, GIF…) is transcoded
    /// once to JPEG with its metadata. Only a downsampled preview is decoded.
    static func preparePhoto(from data: Data, previewMaxPixelSize: Int = 900) -> PreparedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              orientedPixelSize(of: source) != nil,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let preview = downsample(source, maxPixelSize: previewMaxPixelSize) else {
            return nil
        }

        let captureDate = captureDate(of: source)
        let type = UTType(typeIdentifier)
        if let type, type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif) {
            return PreparedPhoto(data: data, preview: preview, captureDate: captureDate)
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return PreparedPhoto(data: output as Data, preview: preview, captureDate: captureDate)
    }

    /// Encodes a camera capture right away, so the form holds a ~1-2 MB JPEG
    /// instead of the ~46 MB full-resolution bitmap, and Save is just a write.
    static func preparePhoto(capturedImage image: UIImage, metadata: [String: Any]?) -> PreparedPhoto? {
        guard let data = encodeJPEG(image, metadata: metadata),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let preview = downsample(source, maxPixelSize: 900) else {
            return nil
        }
        return PreparedPhoto(data: data, preview: preview, captureDate: nil)
    }

    /// EXIF DateTimeOriginal ("yyyy:MM:dd HH:mm:ss"), in its recorded UTC
    /// offset when present, otherwise in the current time zone.
    private static func captureDate(of source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: stamp + offset) {
                return date
            }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: stamp)
    }

    // MARK: Thumbnails

    /// Oriented pixel sizes, memoized per file: reading them is a header parse,
    /// and every thumbnail request needs one to pick its pixel bucket.
    @MainActor
    private static var pixelSizes: [String: CGSize] = [:]

    /// In-flight decodes keyed by cache key, so concurrent requests for the
    /// same thumbnail share one decode. MainActor-serialized: no suspension
    /// point between lookup and insert, so duplicates cannot be created.
    @MainActor
    private static var inFlight: [NSString: Task<UIImage, Never>] = [:]

    /// The photo's displayed (EXIF-oriented) pixel size, if already known.
    @MainActor
    static func knownPixelSize(filename: String) -> CGSize? {
        pixelSizes[filename]
    }

    /// The photo's displayed (EXIF-oriented) pixel size, read from the file
    /// header off the main thread on first use.
    @MainActor
    static func pixelSize(filename: String) async -> CGSize? {
        if let known = pixelSizes[filename] {
            return known
        }
        let size = await Task.detached(priority: .userInitiated) { () -> CGSize? in
            let url = documentsDirectory.appendingPathComponent(filename)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            return orientedPixelSize(of: source)
        }.value
        if let size {
            pixelSizes[filename] = size
        }
        return size
    }

    /// Synchronously returns a cached thumbnail that covers `box` (in pixels)
    /// with the given content mode, without touching disk.
    @MainActor
    static func cachedThumbnail(filename: String, box: CGSize, contentMode: ContentMode) -> UIImage? {
        guard let pixelSize = pixelSizes[filename] else { return nil }
        let bucket = pixelBucket(for: pixelSize, box: box, contentMode: contentMode)
        return imageCache.object(forKey: cacheKey(filename: filename, bucket: bucket))
    }

    /// Returns a thumbnail that covers `box` (in pixels) with the given content
    /// mode, decoding a downsampled copy off-main and caching it.
    @MainActor
    static func loadThumbnail(filename: String, box: CGSize, contentMode: ContentMode) async -> UIImage {
        guard let pixelSize = await pixelSize(filename: filename) else { return placeholder }
        let bucket = pixelBucket(for: pixelSize, box: box, contentMode: contentMode)
        let key = cacheKey(filename: filename, bucket: bucket)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        guard !Task.isCancelled else { return placeholder }

        let usesTier = bucket <= tierPixelSize && Int(max(pixelSize.width, pixelSize.height)) > tierPixelSize
        let decode = Task.detached(priority: .userInitiated) {
            usesTier ? tierThumbnail(filename: filename, maxPixelSize: bucket) : originalThumbnail(filename: filename, maxPixelSize: bucket)
        }
        inFlight[key] = decode
        let image = await decode.value
        inFlight[key] = nil
        // Deleted while decoding (deleteImage drops the size memo): do not
        // put the photo back in the cache.
        guard pixelSizes[filename] != nil else { return image }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        imageCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Deletes an image file from the Documents directory and evicts its cached thumbnails.
    @MainActor
    static func deleteImage(filename: String) {
        deleteFile(filename: filename)
        var buckets = pixelBuckets
        if let size = pixelSizes.removeValue(forKey: filename) {
            buckets.append(Int(max(size.width, size.height)))
        }
        for bucket in buckets {
            imageCache.removeObject(forKey: cacheKey(filename: filename, bucket: bucket))
        }
    }

    /// Removes just the files, for photos that were never displayed (rolled-back
    /// imports) and so have nothing cached in memory. Safe to call from any thread.
    static func deleteFile(filename: String) {
        try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent(filename))
        try? FileManager.default.removeItem(at: tierURL(filename: filename))
    }

    // MARK: Grid tier

    /// Grid-sized requests decode from a small JPEG copy instead of the stored
    /// original: a full HEIC or high-quality JPEG costs ~20-60 ms per cell to
    /// decode, the copy ~2 ms. Kept in Caches, so the system may purge it; it
    /// is rebuilt on the next request.
    private static let tierPixelSize = 1008

    private static let tierDirectory: URL = {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GridThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func tierURL(filename: String) -> URL {
        tierDirectory.appendingPathComponent(filename).appendingPathExtension("jpg")
    }

    private static func originalThumbnail(filename: String, maxPixelSize: Int) -> UIImage {
        let url = documentsDirectory.appendingPathComponent(filename)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return placeholder
        }
        return downsample(source, maxPixelSize: maxPixelSize) ?? placeholder
    }

    private static func tierThumbnail(filename: String, maxPixelSize: Int) -> UIImage {
        let url = tierURL(filename: filename)
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = downsample(source, maxPixelSize: maxPixelSize) {
            return image
        }

        // First request (or purged): build the copy from the original, already
        // oriented, then serve this request from it.
        let originalURL = documentsDirectory.appendingPathComponent(filename)
        guard let original = CGImageSourceCreateWithURL(originalURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let tierImage = downsample(original, maxPixelSize: tierPixelSize)?.cgImage else {
            return placeholder
        }
        let encoded = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, tierImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                // Atomic, so a concurrent request never reads a half-written copy.
                try? (encoded as Data).write(to: url, options: .atomic)
                // deleteFile removes the original before the copy, so if the photo
                // was deleted while this ran, one of the two removals wins.
                if !FileManager.default.fileExists(atPath: originalURL.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        if maxPixelSize >= tierPixelSize {
            return UIImage(cgImage: tierImage)
        }
        guard let source = CGImageSourceCreateWithData(encoded, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = downsample(source, maxPixelSize: maxPixelSize) else {
            return UIImage(cgImage: tierImage)
        }
        return image
    }

    /// Longest-side pixel size to decode so the photo covers (`.fill`) or fits
    /// (`.fit`) a `box` measured in pixels: rounded up to a bucket, and never
    /// larger than the original.
    private static func pixelBucket(for pixelSize: CGSize, box: CGSize, contentMode: ContentMode) -> Int {
        let original = Int(max(pixelSize.width, pixelSize.height).rounded(.up))
        guard pixelSize.width > 0, pixelSize.height > 0, box.width > 0, box.height > 0 else {
            return min(pixelBuckets[0], original)
        }
        let scaleX = box.width / pixelSize.width
        let scaleY = box.height / pixelSize.height
        let scale = contentMode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let needed = Int((CGFloat(original) * scale).rounded(.up))
        guard needed < original, let bucket = pixelBuckets.first(where: { $0 >= needed }), bucket < original else {
            return original
        }
        return bucket
    }

    private static func cacheKey(filename: String, bucket: Int) -> NSString {
        "\(filename)-\(bucket)" as NSString
    }

    private static func orientedPixelSize(of source: CGImageSource) -> CGSize? {
        guard CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        // EXIF orientations 5-8 are rotated a quarter turn, so width/height swap on screen.
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    private static func downsample(_ source: CGImageSource, maxPixelSize: Int) -> UIImage? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Async Thumbnail View

/// Shows a stored photo, decoded at the pixel size its on-screen frame needs.
///
/// `.fill` fills the proposed frame and crops (grid cells). `.fit` sizes itself
/// to the photo's aspect ratio within the proposed frame (full-size views).
struct AsyncThumbnail: View {
    let filename: String
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 12

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    /// The file `image` was decoded from, so a resize keeps showing it while a
    /// sharper decode loads, but a different photo starts from the placeholder.
    @State private var imageFilename: String?
    @State private var aspectRatio: CGFloat?
    /// Laid-out size in points, rounded so live resizes (fold/unfold,
    /// rotation) do not retrigger work every frame.
    @State private var boxSize: CGSize = .zero

    var body: some View {
        sized(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(.secondarySystemFill))
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    } else {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        )
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: (proxy.size.width / 8).rounded(.up) * 8,
                       height: (proxy.size.height / 8).rounded(.up) * 8)
            } action: { newSize in
                boxSize = newSize
            }
            .task(id: RequestKey(filename: filename, box: pixelBox, aspectRatio: contentMode == .fit ? aspectRatio : nil)) {
                guard pixelBox.width > 0, pixelBox.height > 0 else { return }
                if contentMode == .fit, let size = await ImageStore.pixelSize(filename: filename), size.height > 0,
                   aspectRatio != size.width / size.height {
                    // Size the frame to this photo before decoding anything: the
                    // new ratio changes the task id, so this restarts once with
                    // the right box instead of decoding for the 4:3 placeholder.
                    aspectRatio = size.width / size.height
                    return
                }
                if let cached = ImageStore.cachedThumbnail(filename: filename, box: pixelBox, contentMode: contentMode) {
                    show(cached)
                    return
                }
                if imageFilename != filename {
                    image = nil
                }
                let loaded = await ImageStore.loadThumbnail(filename: filename, box: pixelBox, contentMode: contentMode)
                guard !Task.isCancelled else { return }
                show(loaded)
            }
    }

    /// `.fit` takes the photo's aspect ratio (4:3 until it is known); `.fill`
    /// takes whatever frame the caller gives it.
    @ViewBuilder
    private func sized(_ content: some View) -> some View {
        if contentMode == .fit {
            content.aspectRatio(aspectRatio ?? 4.0 / 3.0, contentMode: .fit)
        } else {
            content
        }
    }

    private func show(_ newImage: UIImage) {
        if image !== newImage { image = newImage }
        imageFilename = filename
    }

    private var pixelBox: CGSize {
        CGSize(width: boxSize.width * displayScale, height: boxSize.height * displayScale)
    }

    private struct RequestKey: Hashable {
        let filename: String
        let box: CGSize
        let aspectRatio: CGFloat?
    }
}

// MARK: - Photo Library Export

final class ImageSaver: NSObject {
    /// Saves the original image data (with embedded EXIF) to the photo library,
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
