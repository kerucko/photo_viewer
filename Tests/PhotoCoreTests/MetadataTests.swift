import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

struct MetadataTests {
    @Test func readsEXIFWithoutChangingOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T30 II"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifLensModel: "Test lens",
                kCGImagePropertyExifDateTimeOriginal: "2026:10:23 12:00:00"
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)
        let report = try PhotoMetadata.read(url: url)
        #expect(report.warning == nil)
        let fields = Dictionary(uniqueKeysWithValues: report.sections.flatMap(\.fields).map { ($0.label, $0.value) })
        #expect(fields["Камера"] == "X-T30 II")
        #expect(fields["Объектив"] == "Test lens")
        #expect(fields["ISO"] == "400")
        #expect(fields["Выдержка"] == "1/250 с")
        #expect(fields["Размеры"] == "40 × 80 пикс.")
        #expect(fields["Дата съёмки"] == "2026:10:23 12:00:00")
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func damagedPhotoStillShowsFileInformation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".raf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken raw".utf8).write(to: url)
        let report = try PhotoMetadata.read(url: url)
        #expect(report.warning != nil)
        #expect(report.sections.first?.fields.first?.value == url.lastPathComponent)
        #expect(PhotoMetadata.imageSections([:]).isEmpty)
    }
}
