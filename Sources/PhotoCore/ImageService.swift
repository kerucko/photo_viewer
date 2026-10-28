import AppKit
import CoreImage
import ImageIO

public struct RenderedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(cgImage: CGImage) { self.cgImage = cgImage }
}
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

    public func image(_ resource: PhotoResource, maxPixel: Int?, edit: PhotoEdit = .identity) async throws -> RenderedImage {
        try Task.checkCancellation()
        guard edit.isValid else { throw PhotoEditError.invalidRecipe }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let recipeKey = try encoder.encode(edit).base64EncodedString()
        let generation = PhotoResource.currentGeneration(at: resource.url) ?? "missing"
        let key = "\(generation)|\(resource.url.path)|\(resource.size)|\(resource.modified.timeIntervalSince1970)|\(maxPixel ?? 0)|\(recipeKey)"
        if let cached = cache.object(forKey: key as NSString) { return RenderedImage(cgImage: cached.image) }
        let request = Request()
        return try await withTaskCancellationHandler {
            let result: RenderedImage = try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [self] in
                    guard !request.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    do {
                        let cg = try autoreleasepool {
                            let decodePixel = sourceDecodeLimit(resource, maxPixel: maxPixel, edit: edit)
                            let source = try decode(resource, maxPixel: decodePixel)
                            return try PhotoEditRenderer.render(source, edit: edit, maxPixel: maxPixel, context: context)
                        }
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
    private func sourceDecodeLimit(_ resource: PhotoResource, maxPixel: Int?, edit: PhotoEdit) -> Int? {
        guard let maxPixel, !edit.isIdentity else { return maxPixel }
        guard let source = CGImageSourceCreateWithURL(resource.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped = (5...8).contains(orientation)
        let size = CGSize(width: swapped ? height.doubleValue : width.doubleValue, height: swapped ? width.doubleValue : height.doubleValue)
        return PhotoEditGeometry(sourceSize: size, edit: edit).requiredSourceMaxPixel(sourceSize: size, maxPixel: maxPixel)
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
