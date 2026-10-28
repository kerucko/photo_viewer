import Foundation
import CoreGraphics
import CoreImage

/// Coordinates start at the top-left of the safe, straightened image.
public struct PhotoCrop: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = PhotoCrop()
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000000001 && y + height <= 1.000000001
    }
}

public enum PhotoAspect: String, CaseIterable, Codable, Sendable {
    case free, original, square, threeTwo, fourThree, sixteenNine
    public var title: String {
        switch self {
        case .free: "Свободно"
        case .original: "Исходные"
        case .square: "1:1"
        case .threeTwo: "3:2"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        }
    }
    public func ratio(sourceSize: CGSize, quarterTurns: Int, portrait: Bool) -> Double? {
        guard self != .free else { return nil }
        let ratio: Double
        switch self {
        case .free: return nil
        case .original: ratio = Double(sourceSize.width / sourceSize.height)
        case .square: ratio = 1
        case .threeTwo: ratio = 3.0 / 2
        case .fourThree: ratio = 4.0 / 3
        case .sixteenNine: ratio = 16.0 / 9
        }
        let landscape = max(ratio, 1 / ratio)
        return portrait ? 1 / landscape : landscape
    }
}

public struct PhotoEdit: Codable, Hashable, Sendable {
    public var quarterTurns: Int
    public var angleDegrees: Double
    public var crop: PhotoCrop
    public var aspect: PhotoAspect
    public var portrait: Bool
    public var isMirroredHorizontally: Bool
    public init(quarterTurns: Int = 0, angleDegrees: Double = 0, crop: PhotoCrop = .full,
                aspect: PhotoAspect = .free, portrait: Bool = false, isMirroredHorizontally: Bool = false) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4; self.angleDegrees = angleDegrees
        self.crop = crop; self.aspect = aspect; self.portrait = portrait
        self.isMirroredHorizontally = isMirroredHorizontally
    }
    private enum CodingKeys: String, CodingKey {
        case quarterTurns, angleDegrees, crop, aspect, portrait, isMirroredHorizontally
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quarterTurns = try values.decode(Int.self, forKey: .quarterTurns)
        angleDegrees = try values.decode(Double.self, forKey: .angleDegrees)
        crop = try values.decode(PhotoCrop.self, forKey: .crop)
        aspect = try values.decode(PhotoAspect.self, forKey: .aspect)
        portrait = try values.decode(Bool.self, forKey: .portrait)
        isMirroredHorizontally = try values.decodeIfPresent(Bool.self, forKey: .isMirroredHorizontally) ?? false
    }
    public static let identity = PhotoEdit()
    /// Aspect choice is editor state, and does not by itself change the pixels.
    public var isIdentity: Bool { quarterTurns % 4 == 0 && angleDegrees == 0 && crop == .full && !isMirroredHorizontally }
    public var isValid: Bool { (0...3).contains(quarterTurns) && angleDegrees.isFinite && (-45...45).contains(angleDegrees) && crop.isValid }
    public mutating func rotateClockwise() {
        quarterTurns = (quarterTurns + 1) % 4
        crop = PhotoCrop(x: max(0, 1 - crop.y - crop.height), y: crop.x, width: crop.height, height: crop.width)
        portrait.toggle()
    }
    public mutating func rotateCounterclockwise() {
        quarterTurns = (quarterTurns + 3) % 4
        crop = PhotoCrop(x: crop.y, y: max(0, 1 - crop.x - crop.width), width: crop.height, height: crop.width)
        portrait.toggle()
    }
    /// Reflect the current visible image, carrying its crop to the same content.
    public mutating func mirrorHorizontally() {
        isMirroredHorizontally.toggle()
        // Geometry applies reflection in source space: H R(a) = R(-a) H.
        // Keep later rotations and angle adjustments clockwise on the screen.
        quarterTurns = (4 - quarterTurns) % 4
        angleDegrees = -angleDegrees
        crop.x = max(0, 1 - crop.x - crop.width)
    }
    public mutating func setAspect(_ aspect: PhotoAspect, portrait: Bool, sourceSize: CGSize) {
        self.aspect = aspect; self.portrait = portrait
        guard let ratio = aspect.ratio(sourceSize: sourceSize, quarterTurns: quarterTurns, portrait: portrait) else { return }
        let geometry = PhotoEditGeometry(sourceSize: sourceSize, edit: self)
        let safe = geometry.safeSize
        guard safe.width > 0, safe.height > 0 else { return }
        let width = min(1, ratio * safe.height / safe.width)
        let height = min(1, safe.width / ratio / safe.height)
        crop = PhotoCrop(x: min(max(0, crop.x + crop.width / 2 - width / 2), 1 - width),
                         y: min(max(0, crop.y + crop.height / 2 - height / 2), 1 - height), width: width, height: height)
    }
}

/// Shared top-left geometry for native canvas and Core Image. Positive angles
/// rotate clockwise. The source has already had its EXIF orientation applied.
public struct PhotoEditGeometry: Sendable {
    public let safeSize: CGSize
    public let outputSize: CGSize
    public let cropRect: CGRect
    public let sourceToSafeTransform: CGAffineTransform
    public init(sourceSize: CGSize, edit: PhotoEdit) {
        let width = max(1, sourceSize.width), height = max(1, sourceSize.height)
        let odd = edit.quarterTurns % 2 != 0
        let turnedWidth = odd ? height : width, turnedHeight = odd ? width : height
        let radians = edit.angleDegrees * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        let k = min(turnedWidth / (c * turnedWidth + s * turnedHeight), turnedHeight / (s * turnedWidth + c * turnedHeight))
        safeSize = CGSize(width: k * turnedWidth, height: k * turnedHeight)
        let angle = Double(edit.quarterTurns) * .pi / 2 + radians
        let cosA = cos(angle), sinA = sin(angle)
        let reflection: CGFloat = edit.isMirroredHorizontally ? -1 : 1
        sourceToSafeTransform = CGAffineTransform(a: reflection * cosA, b: reflection * sinA, c: -sinA, d: cosA,
            tx: safeSize.width / 2 - reflection * cosA * width / 2 + sinA * height / 2,
            ty: safeSize.height / 2 - reflection * sinA * width / 2 - cosA * height / 2)
        cropRect = CGRect(x: edit.crop.x * safeSize.width, y: edit.crop.y * safeSize.height,
                          width: edit.crop.width * safeSize.width, height: edit.crop.height * safeSize.height)
        outputSize = cropRect.size
    }
    /// Source pixels needed so maxPixel describes the *cropped result*.
    public func requiredSourceMaxPixel(sourceSize: CGSize, maxPixel: Int) -> Int {
        let outputLong = max(outputSize.width, outputSize.height)
        guard outputLong > 0 else { return maxPixel }
        return Int(min(32768, ceil(max(sourceSize.width, sourceSize.height) * Double(max(1, maxPixel)) / outputLong)))
    }
}

public enum PhotoEditRenderer {
    /// Synchronous by design: call on a worker queue, never on the main actor.
    /// Canvas previews use PhotoEditGeometry directly without re-decoding RAW.
    public static func render(_ image: CGImage, edit: PhotoEdit, maxPixel: Int? = nil) throws -> CGImage {
        try render(image, edit: edit, maxPixel: maxPixel, context: CIContext(options: [.cacheIntermediates: false]))
    }
    static func render(_ image: CGImage, edit: PhotoEdit, maxPixel: Int?, context: CIContext) throws -> CGImage {
        guard edit.isValid else { throw PhotoEditError.invalidRecipe }
        if edit.isIdentity, maxPixel == nil || max(image.width, image.height) <= maxPixel! { return image }
        let size = CGSize(width: image.width, height: image.height)
        let geometry = PhotoEditGeometry(sourceSize: size, edit: edit)
        let t = geometry.sourceToSafeTransform
        // Convert source bottom-left CI coordinates through top-left canvas into
        // cropped bottom-left coordinates. Do not rely on CI extent.origin = 0.
        let transform = CGAffineTransform(a: t.a, b: -t.b, c: -t.c, d: t.d,
            tx: t.c * size.height + t.tx - geometry.cropRect.minX,
            ty: geometry.safeSize.height - t.d * size.height - t.ty - (geometry.safeSize.height - geometry.cropRect.maxY))
        // Clamp the interpolation footprint at source edges. The shared safe
        // rectangle itself stays exact and resolution independent.
        var output = CIImage(cgImage: image).clampedToExtent().transformed(by: transform)
        let ratio: CGFloat = maxPixel.map { min(1, CGFloat(max(1, $0)) / max(geometry.outputSize.width, geometry.outputSize.height)) } ?? 1
        let outputWidth = max(1, floor(geometry.outputSize.width * ratio + 0.000001))
        let outputHeight = max(1, floor(geometry.outputSize.height * ratio + 0.000001))
        // Exact integer output extent, using a single resampling transform.
        let sx = outputWidth / geometry.outputSize.width, sy = outputHeight / geometry.outputSize.height
        output = output.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if let result = context.createCGImage(output, from: outputRect,
            format: colorSpace.model == .monochrome ? .L8 : .RGBA8, colorSpace: colorSpace) { return result }
        // Core Image can have no rendering device in a headless session, even
        // with its software option. An affine bitmap draw uses the very same
        // geometry and source profile without a GPU or WindowServer dependency.
        let gray = colorSpace.model == .monochrome
        guard let bitmap = CGContext(data: nil, width: Int(outputWidth), height: Int(outputHeight), bitsPerComponent: 8,
            bytesPerRow: Int(outputWidth) * (gray ? 1 : 4), space: colorSpace,
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.unreadable }
        bitmap.interpolationQuality = .high
        bitmap.setShouldAntialias(false)
        bitmap.scaleBy(x: sx, y: sy)
        bitmap.concatenate(transform)
        bitmap.draw(image, in: CGRect(origin: .zero, size: size))
        guard let result = bitmap.makeImage() else { throw ImageFailure.unreadable }
        return result
    }
}

public enum PhotoEditError: LocalizedError {
    case invalidRecipe, changedResources, invalidStore, changedStore, outsideRoot
    public var errorDescription: String? {
        switch self {
        case .invalidRecipe: "Некорректные параметры кадрирования."
        case .changedResources: "Ресурсы снимка изменились после открытия редактора. Откройте снимок заново."
        case .invalidStore: "Хранилище правок повреждено или имеет неизвестную версию. Оно не будет перезаписано."
        case .changedStore: "Хранилище правок изменилось в другом окне. Откройте снимок заново."
        case .outsideRoot: "Ресурс снимка находится вне открытой папки или библиотеки."
        }
    }
}
