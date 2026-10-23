import Foundation
import ImageIO

public struct MetadataField: Identifiable, Sendable {
    public let label: String
    public let value: String
    public var id: String { label }
}

public struct MetadataSection: Identifiable, Sendable {
    public let title: String
    public let fields: [MetadataField]
    public var id: String { title }
}

public struct PhotoMetadata: Sendable {
    public let sections: [MetadataSection]
    public let warning: String?

    /// Reads container properties without decoding the full JPEG/RAW image.
    public static func read(url: URL) throws -> PhotoMetadata {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey])
        var file: [MetadataField] = [MetadataField(label: "Имя", value: url.lastPathComponent), MetadataField(label: "Где", value: url.deletingLastPathComponent().path)]
        if let size = values.fileSize, values.isDirectory != true { file.append(MetadataField(label: "Размер файла", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        if let date = values.creationDate { file.append(MetadataField(label: "Создан", value: date.formatted(date: .numeric, time: .standard))) }
        if let date = values.contentModificationDate { file.append(MetadataField(label: "Изменён", value: date.formatted(date: .numeric, time: .standard))) }
        var sections = [MetadataSection(title: "Файл", fields: file)]
        if values.isDirectory == true { return PhotoMetadata(sections: sections, warning: nil) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return PhotoMetadata(sections: sections, warning: "Метаданные изображения недоступны.")
        }
        sections += imageSections(properties)
        return PhotoMetadata(sections: sections, warning: nil)
    }

    static func imageSections(_ properties: [String: Any]) -> [MetadataSection] {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            guard let value else { return nil }
            let result = (value as? String) ?? (value as? NSNumber)?.stringValue
            return result?.isEmpty == false ? result : nil
        }
        func number(_ value: Any?) -> Double? {
            guard let n = (value as? NSNumber)?.doubleValue, n.isFinite else { return nil }; return n
        }
        func formatted(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0...2))) }
        func field(_ label: String, _ value: String?) -> MetadataField? { value.map { MetadataField(label: label, value: $0) } }
        var dimensions: String?
        if let w = number(properties[kCGImagePropertyPixelWidth as String]), let h = number(properties[kCGImagePropertyPixelHeight as String]) {
            let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            let swapped = (5...8).contains(orientation)
            dimensions = "\(Int(swapped ? h : w)) × \(Int(swapped ? w : h)) пикс."
        }
        let imageFields = [
            field("Размеры", dimensions),
            field("Цветовая модель", text(properties[kCGImagePropertyColorModel as String])),
            field("Профиль", text(properties[kCGImagePropertyProfileName as String])),
            field("Глубина", text(properties[kCGImagePropertyDepth as String]).map { "\($0) бит" })
        ].compactMap { $0 }
        let exposure = number(exif[kCGImagePropertyExifExposureTime as String]).flatMap { time -> String? in
            guard time > 0 else { return nil }
            return time < 1 ? "1/\(formatted(1 / time)) с" : "\(formatted(time)) с"
        }
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.map(\.stringValue).joined(separator: ", ")
        let shooting = [
            field("Дата съёмки", text(exif[kCGImagePropertyExifDateTimeOriginal as String])),
            field("Часовой пояс", text(exif["OffsetTimeOriginal"])),
            field("Производитель", text(tiff[kCGImagePropertyTIFFMake as String])),
            field("Камера", text(tiff[kCGImagePropertyTIFFModel as String])),
            field("Объектив", text(exif[kCGImagePropertyExifLensModel as String])),
            field("Выдержка", exposure),
            field("Диафрагма", number(exif[kCGImagePropertyExifFNumber as String]).map { "ƒ/\(formatted($0))" }),
            field("ISO", iso),
            field("Фокусное расстояние", number(exif[kCGImagePropertyExifFocalLength as String]).map { "\(formatted($0)) мм" }),
            field("Эквивалент 35 мм", number(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]).map { "\(formatted($0)) мм" }),
            field("Экспокоррекция", number(exif[kCGImagePropertyExifExposureBiasValue as String]).map { "\(formatted($0)) EV" }),
            field("Вспышка", (exif[kCGImagePropertyExifFlash as String] as? NSNumber).map { ($0.intValue & 1) == 1 ? "Сработала" : "Не сработала" }),
            field("ПО", text(tiff[kCGImagePropertyTIFFSoftware as String]))
        ].compactMap { $0 }
        let location = [
            field("Широта", number(gps[kCGImagePropertyGPSLatitude as String]).map { "\($0)° \(text(gps[kCGImagePropertyGPSLatitudeRef as String]) ?? "")" }),
            field("Долгота", number(gps[kCGImagePropertyGPSLongitude as String]).map { "\($0)° \(text(gps[kCGImagePropertyGPSLongitudeRef as String]) ?? "")" })
        ].compactMap { $0 }
        return [MetadataSection(title: "Изображение", fields: imageFields), MetadataSection(title: "Съёмка", fields: shooting), MetadataSection(title: "Местоположение", fields: location)].filter { !$0.fields.isEmpty }
    }
}
