import Foundation
import Testing
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

struct PhotoMirroringTests {
    private let size = CGSize(width: 120, height: 80)

    private func near(_ actual: CGPoint, _ expected: CGPoint) {
        #expect(abs(actual.x - expected.x) < 0.000001)
        #expect(abs(actual.y - expected.y) < 0.000001)
    }

    private func outputPoint(_ point: CGPoint, _ geometry: PhotoEditGeometry) -> CGPoint {
        let safe = point.applying(geometry.sourceToSafeTransform)
        return CGPoint(x: safe.x - geometry.cropRect.minX, y: safe.y - geometry.cropRect.minY)
    }

    @Test func mirrorReflectsVisibleFrameAndTwiceRestoresRecipe() {
        for turn in 0..<4 {
            for angle in [-45.0, -17.3, 0, 26.2, 45] {
                for initiallyMirrored in [false, true] {
                    let original = PhotoEdit(quarterTurns: turn, angleDegrees: angle,
                        crop: PhotoCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.375),
                        aspect: .threeTwo, portrait: true, isMirroredHorizontally: initiallyMirrored)
                    let before = PhotoEditGeometry(sourceSize: size, edit: original)
                    var edit = original
                    edit.mirrorHorizontally()
                    #expect(edit.isValid)
                    #expect(edit.isMirroredHorizontally != initiallyMirrored)
                    #expect(edit.portrait == original.portrait && edit.aspect == original.aspect)
                    let after = PhotoEditGeometry(sourceSize: size, edit: edit)
                    #expect(before.safeSize == after.safeSize && before.outputSize == after.outputSize)
                    for sourcePoint in [CGPoint.zero, CGPoint(x: 17, y: 23), CGPoint(x: 120, y: 80)] {
                        let point = outputPoint(sourcePoint, before)
                        near(outputPoint(sourcePoint, after), CGPoint(x: before.outputSize.width - point.x, y: point.y))
                    }
                    edit.mirrorHorizontally()
                    #expect(edit == original)
                }
            }
        }
        var edit = PhotoEdit.identity
        edit.mirrorHorizontally()
        #expect(!edit.isIdentity)
        #expect(Set([PhotoEdit.identity, edit]).count == 2)
        edit.mirrorHorizontally()
        #expect(edit.isIdentity)
    }

    @Test func rotationsAndAngleAdjustmentsKeepScreenDirectionsAfterMirror() {
        for turn in 0..<4 {
            for angle in [-23.0, 0, 19] {
                var mirrored = PhotoEdit(quarterTurns: turn, angleDegrees: angle,
                    crop: PhotoCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.375))
                mirrored.mirrorHorizontally()
                let before = PhotoEditGeometry(sourceSize: size, edit: mirrored)
                for clockwise in [false, true] {
                    var rotated = mirrored
                    if clockwise { rotated.rotateClockwise() } else { rotated.rotateCounterclockwise() }
                    let after = PhotoEditGeometry(sourceSize: size, edit: rotated)
                    #expect(rotated.isValid)
                    near(CGPoint(x: after.outputSize.width, y: after.outputSize.height),
                         CGPoint(x: before.outputSize.height, y: before.outputSize.width))
                    for sourcePoint in [CGPoint.zero, CGPoint(x: 31, y: 47), CGPoint(x: 120, y: 80)] {
                        let point = outputPoint(sourcePoint, before)
                        let expected = clockwise ? CGPoint(x: before.outputSize.height - point.y, y: point.x)
                            : CGPoint(x: point.y, y: before.outputSize.width - point.x)
                        near(outputPoint(sourcePoint, after), expected)
                    }
                }
                var adjusted = mirrored
                adjusted.angleDegrees += 5
                let after = PhotoEditGeometry(sourceSize: size, edit: adjusted)
                let previous = before.sourceToSafeTransform
                let current = after.sourceToSafeTransform
                let radians = 5.0 * .pi / 180
                // Translation changes with the safe rectangle; the source x
                // vector must still turn clockwise by the requested five degrees.
                near(CGPoint(x: current.a, y: current.b),
                     CGPoint(x: cos(radians) * previous.a - sin(radians) * previous.b,
                             y: sin(radians) * previous.a + cos(radians) * previous.b))
            }
        }
    }

    private func fixture(space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        let gray = space.model == .monochrome
        let bitmap = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
            bytesPerRow: 120 * (gray ? 1 : 4), space: space,
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<4 {
            for column in 0..<6 {
                let color = gray ? CGColor(gray: CGFloat(column + row) / 10, alpha: 1)
                    : CGColor(red: CGFloat(column) / 5, green: CGFloat(row) / 3, blue: CGFloat(5 - column) / 5, alpha: 1)
                bitmap.setFillColor(color)
                bitmap.fill(CGRect(x: column * 20, y: row * 20, width: 20, height: 20))
            }
        }
        return try #require(bitmap.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let bitmap = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    @Test func asymmetricPixelsMirrorAcrossAllQuarterTurnsAndStraightening() throws {
        let source = try fixture()
        let contexts = [CIContext(options: [.cacheIntermediates: false]),
                        CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])]
        for context in contexts {
            for turn in 0..<4 {
                for angle in [-17.0, 0, 23] {
                    let original = PhotoEdit(quarterTurns: turn, angleDegrees: angle,
                        crop: PhotoCrop(x: 0.125, y: 0.125, width: 0.75, height: 0.75))
                    var mirror = original
                    mirror.mirrorHorizontally()
                    let before = try PhotoEditRenderer.render(source, edit: original, maxPixel: 60, context: context)
                    let after = try PhotoEditRenderer.render(source, edit: mirror, maxPixel: 60, context: context)
                    #expect(before.width == after.width && before.height == after.height)
                    let a = try pixels(before), b = try pixels(after)
                    for y in 0..<before.height {
                        for x in 0..<before.width {
                            for channel in 0..<4 {
                                let left = a[(y * before.width + x) * 4 + channel]
                                let right = b[(y * after.width + after.width - 1 - x) * 4 + channel]
                                #expect(abs(Int(left) - Int(right)) <= 3)
                            }
                        }
                    }
                    #expect(a != b)
                }
            }
        }
    }

    @Test func mirrorPreservesProfilesAndFinalResolution() throws {
        for space in [CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, CGColorSpace(name: CGColorSpace.displayP3)!] {
            let source = try fixture(space: space)
            let result = try PhotoEditRenderer.render(source, edit: PhotoEdit(isMirroredHorizontally: true), maxPixel: 60)
            #expect(result.width == 60 && result.height == 40)
            #expect(result.colorSpace?.name == space.name)
            #expect(result.colorSpace?.model == space.model)
        }
    }

    @Test func codableReadsLegacyAndRoundTripsMirror() throws {
        let legacy = Data(#"{"quarterTurns":1,"angleDegrees":12,"crop":{"x":0,"y":0,"width":1,"height":1},"aspect":"free","portrait":false}"#.utf8)
        var edit = try JSONDecoder().decode(PhotoEdit.self, from: legacy)
        #expect(!edit.isMirroredHorizontally)
        edit.mirrorHorizontally()
        #expect(try JSONDecoder().decode(PhotoEdit.self, from: JSONEncoder().encode(edit)) == edit)
    }

    @Test func imageServiceKeepsMirroredCacheDistinctAndReusesRecipe() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try fixture(), nil)
        #expect(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: url)
        let resource = PhotoResource(url: url)
        let original = try await ImageService.shared.image(resource, maxPixel: 60)
        var edit = PhotoEdit.identity
        edit.mirrorHorizontally()
        let mirror = try await ImageService.shared.image(resource, maxPixel: 60, edit: edit)
        let cached = try await ImageService.shared.image(resource, maxPixel: 60, edit: edit)
        #expect(mirror.cgImage === cached.cgImage)
        #expect(original.cgImage !== mirror.cgImage)
        let a = try pixels(original.cgImage), b = try pixels(mirror.cgImage)
        #expect(a != b)
        for y in 0..<original.cgImage.height {
            for x in 0..<original.cgImage.width {
                for channel in 0..<4 {
                    #expect(abs(Int(a[(y * 60 + x) * 4 + channel])
                        - Int(b[(y * 60 + 59 - x) * 4 + channel])) <= 3)
                }
            }
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func persistedPairMirrorAndLegacyStoreLeaveOriginalsUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let resources = try ["pair.jpg", "pair.raf"].map { name in
            let url = originals.appendingPathComponent(name)
            try Data(("untouched " + name).utf8).write(to: url)
            return PhotoResource(url: url)
        }
        let bytes = try resources.map { try Data(contentsOf: $0.url) }
        let dates = try resources.map { try $0.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let asset = PhotoAsset(resources: resources)
        let storage = root.appendingPathComponent("edits.json")
        let store = PhotoEditStore(folder: originals, storageURL: storage)
        var edit = PhotoEdit(quarterTurns: 1, angleDegrees: 12, crop: PhotoCrop(x: 0.125, width: 0.75))
        edit.mirrorHorizontally()
        try await store.save(edit, for: asset, token: store.load(for: asset).token)
        let restart = PhotoEditStore(folder: originals, storageURL: storage)
        #expect(try await restart.load(for: asset).edit == edit)
        #expect(try await restart.recipe(for: asset).edit == edit)
        // Remove only the new optional field to reproduce a version-1 store.
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as? [String: Any])
        #expect(document["version"] as? Int == 1)
        var records = try #require(document["records"] as? [[String: Any]])
        var recipe = try #require(records[0]["edit"] as? [String: Any])
        recipe.removeValue(forKey: "isMirroredHorizontally")
        records[0]["edit"] = recipe; document["records"] = records
        try JSONSerialization.data(withJSONObject: document).write(to: storage, options: .atomic)
        let legacyStore = PhotoEditStore(folder: originals, storageURL: storage)
        var expectedLegacy = edit; expectedLegacy.isMirroredHorizontally = false
        #expect(try await legacyStore.load(for: asset).edit == expectedLegacy)
        #expect(try resources.map { try Data(contentsOf: $0.url) } == bytes)
        #expect(try resources.map { try $0.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } == dates)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: originals.path)) == Set(["pair.jpg", "pair.raf"]))
    }
}
