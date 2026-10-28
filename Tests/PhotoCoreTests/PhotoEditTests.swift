import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

struct PhotoEditTests {
    private func image(width: Int = 400, height: Int = 200) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return try #require(context.makeImage())
    }
    @Test func quarterTurnsCarryCropAndRoundTrip() throws {
        let original = PhotoEdit(crop: PhotoCrop(x: 0.15, y: 0.2, width: 0.6, height: 0.3), aspect: .threeTwo)
        var edit = original; edit.rotateClockwise()
        #expect(abs(edit.crop.x - 0.5) < 0.000001); #expect(edit.crop.y == 0.15)
        #expect(edit.crop.width == 0.3); #expect(edit.crop.height == 0.6)
        for _ in 0..<3 { edit.rotateClockwise() }
        #expect(edit.quarterTurns == original.quarterTurns)
        #expect(abs(edit.crop.x - original.crop.x) < 0.000001)
        #expect(abs(edit.crop.y - original.crop.y) < 0.000001)
        edit.rotateCounterclockwise(); edit.rotateClockwise()
        #expect(abs(edit.crop.x - original.crop.x) < 0.000001)
        #expect(try JSONDecoder().decode(PhotoEdit.self, from: JSONEncoder().encode(edit)) == edit)
    }
    @Test func safeRectangleStaysInsideRotatedSource() throws {
        for size in [CGSize(width: 800, height: 400), CGSize(width: 400, height: 800)] {
            for turn in 0..<4 {
                for angle in [-45.0, -22.2, 0, 17.3, 45] {
                    let edit = PhotoEdit(quarterTurns: turn, angleDegrees: angle)
                    let geometry = PhotoEditGeometry(sourceSize: size, edit: edit)
                    let inverse = geometry.sourceToSafeTransform.inverted()
                    for corner in [CGPoint.zero, CGPoint(x: geometry.safeSize.width, y: 0), CGPoint(x: 0, y: geometry.safeSize.height), CGPoint(x: geometry.safeSize.width, y: geometry.safeSize.height)] {
                        let point = corner.applying(inverse)
                        #expect(point.x >= -0.000001 && point.x <= size.width + 0.000001)
                        #expect(point.y >= -0.000001 && point.y <= size.height + 0.000001)
                    }
                    let expected = turn % 2 == 0 ? size.width / size.height : size.height / size.width
                    #expect(abs(geometry.safeSize.width / geometry.safeSize.height - expected) < 0.000001)
                }
            }
        }
    }
    @Test func allAspectChoicesFitAndPreserveNearbyCenter() {
        for aspect in PhotoAspect.allCases where aspect != .free {
            for portrait in [false, true] {
                let size = CGSize(width: 900, height: 600)
                var edit = PhotoEdit(angleDegrees: 23, crop: PhotoCrop(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
                edit.setAspect(aspect, portrait: portrait, sourceSize: size)
                #expect(edit.crop.isValid)
                let geometry = PhotoEditGeometry(sourceSize: size, edit: edit)
                #expect(abs(geometry.outputSize.width / geometry.outputSize.height - aspect.ratio(sourceSize: size, quarterTurns: 0, portrait: portrait)!) < 0.000001)
            }
        }
    }
    @Test func rendererAvoidsTransparentEdgesAndLimitsFinalCrop() throws {
        let source = try image()
        for turn in 0..<4 {
            for angle in [-45.0, -13.3, 0, 24.5, 45] {
                let edit = PhotoEdit(quarterTurns: turn, angleDegrees: angle)
                let result = try PhotoEditRenderer.render(source, edit: edit, maxPixel: 80)
                #expect(max(result.width, result.height) == 80)
                // Ask a known RGBA context instead of depending on the CI image's
                // byte order or alpha representation.
                let rgba = try #require(CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
                    bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                rgba.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
                let samples = rgba.data!.assumingMemoryBound(to: UInt8.self)
                var minAlpha: UInt8 = 255
                for y in 0..<result.height {
                    for x in 0..<result.width { minAlpha = min(minAlpha, samples[(y * result.width + x) * 4 + 3]) }
                }
                #expect(minAlpha == 255)
            }
        }
    }
    @Test func editedImageServiceUsesFinalResolutionAndDistinctCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: 2000, height: 1000), nil)
        #expect(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: url)
        let resource = PhotoResource(url: url, size: Int64(before.count))
        let edit = PhotoEdit(crop: PhotoCrop(x: 0.2, y: 0.2, width: 0.1, height: 0.1))
        let edited = try await ImageService.shared.image(resource, maxPixel: 100, edit: edit)
        #expect(edited.cgImage.width == 100); #expect(edited.cgImage.height == 50)
        let cached = try await ImageService.shared.image(resource, maxPixel: 100, edit: edit)
        #expect(edited.cgImage === cached.cgImage)
        let ordinary = try await ImageService.shared.image(resource, maxPixel: 100)
        #expect(ordinary.cgImage.width == 100)
        let rotated = try await ImageService.shared.image(resource, maxPixel: 100, edit: PhotoEdit(quarterTurns: 1))
        #expect(rotated.cgImage.width == 50); #expect(rotated.cgImage.height == 100)
        #expect(try Data(contentsOf: url) == before)
    }
    @Test func externalReplacementWithPreservedSizeAndDateInvalidatesImageCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try image(width: 80, height: 40)
        func write(_ image: CGImage) throws -> Data {
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
            return try Data(contentsOf: url)
        }
        var first = try write(source)
        let bitmap = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        var second = try write(#require(bitmap.makeImage()))
        let length = max(first.count, second.count)
        first.append(Data(count: length - first.count)); second.append(Data(count: length - second.count))
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try first.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let resource = PhotoResource(url: url, size: Int64(length), modified: date)
        let original = try await ImageService.shared.image(resource, maxPixel: 80)
        try second.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let freshResource = PhotoResource(url: url, size: Int64(length), modified: date)
        #expect(freshResource.fileGeneration != resource.fileGeneration)
        #expect(PhotoAsset(resources: [freshResource]) != PhotoAsset(resources: [resource]))
        #expect(PhotoResource(url: url, size: Int64(length), modified: date) == freshResource)
        // Even a caller retaining the old snapshot must get the new pixels.
        let replaced = try await ImageService.shared.image(resource, maxPixel: 80)
        #expect(original.cgImage !== replaced.cgImage)
        let pixel = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixel.draw(replaced.cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let channels = pixel.data!.assumingMemoryBound(to: UInt8.self)
        #expect(channels[2] > 240); #expect(channels[0] < 10)
    }
    @Test func preservesGrayAndRGBProfilesWhenEdited() throws {
        for space in [CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, CGColorSpace(name: CGColorSpace.displayP3)!] {
            let gray = space.model == .monochrome
            let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: gray ? 80 : 320,
                space: space, bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray ? CGColor(gray: 0.5, alpha: 1) : CGColor(red: 1, green: 0.2, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            let source = try #require(context.makeImage())
            let edited = try PhotoEditRenderer.render(source, edit: PhotoEdit(quarterTurns: 1, angleDegrees: 12))
            #expect(edited.colorSpace?.model == space.model)
            #expect(edited.colorSpace?.name == space.name)
        }
    }
    @Test func topLeftCropMatchesRendererCorners() throws {
        // The fixture draws green in the upper-left half of its bitmap.
        let result = try PhotoEditRenderer.render(try image(), edit: PhotoEdit(crop: PhotoCrop(width: 0.5, height: 0.5)))
        #expect(result.width == 200); #expect(result.height == 100)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
        #expect(pixel[1] > 240); #expect(pixel[0] < 10)
    }
}
