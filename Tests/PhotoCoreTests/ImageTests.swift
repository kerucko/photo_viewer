import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

struct ImageTests {
    @Test func jpegOrientationThumbnailAndCancellation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)
        let resource = PhotoResource(url: url, size: Int64(original.count))
        let full = try await ImageService.shared.image(resource, maxPixel: nil)
        #expect(full.cgImage.width == 40); #expect(full.cgImage.height == 80)
        let thumb = try await ImageService.shared.image(resource, maxPixel: 20)
        #expect(thumb.cgImage.width == 10); #expect(thumb.cgImage.height == 20)
        #expect(try Data(contentsOf: url) == original)
        let task = Task { try await ImageService.shared.image(resource, maxPixel: 1) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled decode returned a result") }
        catch is CancellationError { }
    }
    @Test func corruptImageFails() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an image".utf8).write(to: url)
        do { _ = try await ImageService.shared.image(PhotoResource(url: url), maxPixel: nil); Issue.record("Corrupt JPEG was accepted") }
        catch { #expect(!(error is CancellationError)) }
    }
}
