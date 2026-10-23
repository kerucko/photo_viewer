import AppKit
import CoreImage
import ImageIO

public struct RenderedImage: @unchecked Sendable { public let cgImage: CGImage }
enum ImageFailure: LocalizedError {
    case unreadable
    var errorDescription: String? { "Не удалось прочитать изображение. Возможно, файл повреждён или носитель отключён." }
}

/// All decodes run on a bounded queue, never on the UI thread.
public final class ImageService: @unchecked Sendable {
    public static let shared = ImageService()
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q
    }()
    private let cache = NSCache<NSString, ImageBox>()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private init() { cache.totalCostLimit = 512 * 1024 * 1024 }
    private final class ImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    public func image(_ resource: PhotoResource, maxPixel: Int?) async throws -> RenderedImage {
        try Task.checkCancellation()
        let key = "\(resource.url.path)|\(resource.size)|\(resource.modified.timeIntervalSince1970)|\(maxPixel ?? 0)"
        if let cached = cache.object(forKey: key as NSString) { return RenderedImage(cgImage: cached.image) }
        let request = Request()
        return try await withTaskCancellationHandler {
            let result: RenderedImage = try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [self] in
                    guard !request.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    do {
                        let cg = try autoreleasepool { try decode(resource, maxPixel: maxPixel) }
                        guard !request.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                        cache.setObject(ImageBox(cg), forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
                        continuation.resume(returning: RenderedImage(cgImage: cg))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            // Queued requests skip decoding; in-flight Core Image calls finish but
            // cannot publish or enter the cache after cancellation.
            request.cancel()
        }
    }
    private func decode(_ resource: PhotoResource, maxPixel: Int?) throws -> CGImage {
        if resource.isRAW && maxPixel == nil {
            guard let filter = CIRAWFilter(imageURL: resource.url), let output = filter.outputImage,
                  let cg = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw ImageFailure.unreadable }
            return cg
        }
        guard let source = CGImageSourceCreateWithURL(resource.url as CFURL, nil) else { throw ImageFailure.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? 32768,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageFailure.unreadable }
        return image
    }
}
