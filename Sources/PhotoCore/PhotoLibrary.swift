import Foundation
import CryptoKit
import Darwin

public struct LibrarySnapshot: Sendable {
    public var entries: [CatalogEntry]
    public var issues: [String]
}

public struct ImportReport: Sendable {
    public var imported = 0
    public var skipped = 0
    public var issues: [String] = []
}
public struct TrashReport: Sendable {
    public var trashed: [URL] = []
    public var failures: [String] = []
    public var succeeded: Bool { failures.isEmpty && !trashed.isEmpty }
}

public enum PhotoTrash {
    public static func trash(_ asset: PhotoAsset) -> TrashReport {
        trash(asset, move: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) })
    }
    // Injectable operation keeps tests out of the user's Trash.
    static func trash(_ asset: PhotoAsset, move: (URL) throws -> Void) -> TrashReport {
        var result = TrashReport()
        do { for resource in asset.resources { try LibraryFiles.checkRegular(resource.url) } }
        catch { result.failures.append(error.localizedDescription); return result }
        for resource in asset.resources {
            do { try move(resource.url); result.trashed.append(resource.url) }
            catch { result.failures.append("\(resource.url.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }
}

private enum LibraryFiles {
    static func fail(_ message: String) -> NSError { NSError(domain: "PhotoLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func checkRegular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw fail("Не обычный файл или путь содержит символьную ссылку: \(url.path)")
        }
    }
    static func hash(_ url: URL) throws -> String {
        try checkRegular(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func xattrs(_ url: URL) throws -> [String: Data] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw fail("Не удалось прочитать метаданные: \(url.path)") }
        if size == 0 { return [:] }
        var bytes = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &bytes, size, XATTR_NOFOLLOW) == size else { throw fail("Метаданные изменились: \(url.path)") }
        var result: [String: Data] = [:]
        for name in bytes.split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }) {
            let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard count >= 0 else { throw fail("Не удалось прочитать \(name)") }
            var data = Data(count: count)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
            guard read == count else { throw fail("Не удалось прочитать \(name)") }
            result[name] = data
        }
        return result
    }
}

/// Managed originals are never overwritten. The manifest is also the future sync journal.
public actor PhotoLibrary {
    public nonisolated let root: URL
    private struct Record: Codable {
        let source: String
        var origin: String? = nil
        let relative: String
        let stored: String
        let hash: String
        var deleted: Bool
        var pendingDeletion: Bool? = nil
    }
    private struct Manifest: Codable {
        var version = 1
        var records: [Record] = []
    }
    public init(root: URL) { self.root = root.standardizedFileURL }
    private var manifestURL: URL { root.appendingPathComponent("library.json") }
    private func load() throws -> Manifest {
        guard root.path == root.resolvingSymlinksInPath().path else { throw LibraryFiles.fail("Библиотека не может быть символьной ссылкой") }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Originals").path) {
                throw LibraryFiles.fail("В библиотеке есть Originals, но отсутствует library.json")
            }
            return Manifest()
        }
        try LibraryFiles.checkRegular(manifestURL)
        var result = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard result.version == 1, Set(result.records.map(\.stored)).count == result.records.count,
              result.records.allSatisfy({ $0.stored.hasPrefix("Originals/") && !$0.stored.split(separator: "/").contains("..") && !$0.stored.hasPrefix("/") }) else {
            throw LibraryFiles.fail("Неподдерживаемый или повреждённый каталог библиотеки")
        }
        // Reconcile an interrupted Trash operation using only explicit persisted intent.
        var recovered = false
        for index in result.records.indices where result.records[index].pendingDeletion == true {
            result.records[index].deleted = !FileManager.default.fileExists(atPath: root.appendingPathComponent(result.records[index].stored).path)
            result.records[index].pendingDeletion = nil
            recovered = true
        }
        if recovered { try save(result) }
        return result
    }
    private func save(_ manifest: Manifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }
    public func entries() throws -> [CatalogEntry] { try snapshot().entries }
    public func snapshot() throws -> LibrarySnapshot {
        let manifest = try load()
        var resources: [PhotoResource] = [], issues: [String] = []
        for record in manifest.records where !record.deleted {
            let url = root.appendingPathComponent(record.stored)
            do {
                try LibraryFiles.checkRegular(url)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                resources.append(PhotoResource(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            } catch { issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return LibrarySnapshot(entries: FolderCatalog.sorted(FolderCatalog.pair(resources).map { CatalogEntry(url: $0.preferred.url, asset: $0) }), issues: issues)
    }
    public func importPhotos(from source: URL) throws -> ImportReport {
        let source = source.standardizedFileURL
        let canonical = source.resolvingSymlinksInPath()
        guard source == canonical else { throw LibraryFiles.fail("Источник не может содержать символьные ссылки") }
        let a = source.path + "/", b = root.path + "/"
        guard !a.hasPrefix(b), !b.hasPrefix(a) else { throw LibraryFiles.fail("Источник и библиотека не должны пересекаться") }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
        guard values.isDirectory == true else { throw LibraryFiles.fail("Выберите папку источника") }
        let identity = source.path + "|" + (values.volumeUUIDString ?? "")
        let sourceID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        var manifest = try load(), report = ImportReport()
        try save(manifest)
        var enumerationErrors: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { url, error in
            enumerationErrors.append("\(url.lastPathComponent): \(error.localizedDescription)"); return true
        }) else { throw LibraryFiles.fail("Не удалось прочитать источник") }
        for case let url as URL in enumerator {
            do {
                let flags = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if flags.isSymbolicLink == true { report.issues.append("Пропущена символьная ссылка: \(url.lastPathComponent)"); continue }
                if flags.isDirectory == true { continue }
                guard ["jpg", "jpeg", "raf"].contains(url.pathExtension.lowercased()) else { continue }
                let relative = String(url.path.dropFirst(a.count))
                let hash = try LibraryFiles.hash(url)
                if let record = manifest.records.first(where: { $0.source == sourceID && $0.relative == relative }) {
                    guard record.hash == hash else { throw LibraryFiles.fail("Конфликт: исходный файл изменён — \(relative)") }
                    if record.deleted { report.skipped += 1; continue }
                    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(record.stored).path) else { throw LibraryFiles.fail("Файл библиотеки отсутствует: \(relative)") }
                    guard try LibraryFiles.hash(root.appendingPathComponent(record.stored)) == record.hash else {
                        throw LibraryFiles.fail("Файл библиотеки изменён: \(relative). Синхронизация изменений ещё не поддерживается")
                    }
                    report.skipped += 1; continue
                }
                let stored = "Originals/\(sourceID)/\(relative)", destination = root.appendingPathComponent(stored)
                let directory = destination.deletingLastPathComponent()
                guard directory.path == directory.resolvingSymlinksInPath().path else { throw LibraryFiles.fail("Папка назначения содержит ссылку") }
                if FileManager.default.fileExists(atPath: destination.path) {
                    // Recover a copy completed just before an interrupted manifest save.
                    let metadata = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    let existing = try destination.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    guard try LibraryFiles.hash(destination) == hash,
                          try LibraryFiles.xattrs(destination) == LibraryFiles.xattrs(url),
                          existing.creationDate == metadata.creationDate,
                          existing.contentModificationDate == metadata.contentModificationDate else {
                        throw LibraryFiles.fail("Конфликт существующего файла назначения: \(relative)")
                    }
                    manifest.records.append(Record(source: sourceID, origin: identity, relative: relative, stored: stored, hash: hash, deleted: false))
                    do { try save(manifest) } catch { manifest.records.removeLast(); throw error }
                    report.imported += 1
                    continue
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let temporary = directory.appendingPathComponent(".import-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let metadata = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let attributes = try LibraryFiles.xattrs(url)
                try FileManager.default.copyItem(at: url, to: temporary)
                let copied = try temporary.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                guard try LibraryFiles.hash(temporary) == hash, try LibraryFiles.hash(url) == hash,
                      try LibraryFiles.xattrs(temporary) == attributes,
                      copied.creationDate == metadata.creationDate, copied.contentModificationDate == metadata.contentModificationDate else {
                    throw LibraryFiles.fail("Не удалось сохранить содержимое или метаданные: \(relative)")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                manifest.records.append(Record(source: sourceID, origin: identity, relative: relative, stored: stored, hash: hash, deleted: false))
                // Save after every file: earlier successful copies remain discoverable on later failure.
                do { try save(manifest) }
                catch {
                    manifest.records.removeLast()
                    // Only our newly copied destination is eligible for cleanup.
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                report.imported += 1
            } catch { report.issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        report.issues += enumerationErrors
        return report
    }
    public func trash(_ asset: PhotoAsset) throws -> TrashReport {
        try trash(asset, move: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }
    func trash(_ asset: PhotoAsset, move: (URL) throws -> Void) throws -> TrashReport {
        var manifest = try load()
        let indices = try asset.resources.map { resource in
            guard let index = manifest.records.firstIndex(where: { !$0.deleted && root.appendingPathComponent($0.stored) == resource.url }) else { throw LibraryFiles.fail("Снимок не принадлежит библиотеке") }
            try LibraryFiles.checkRegular(resource.url)
            return index
        }
        // Persist intent first; a crash must never cause automatic restoration from SD.
        for index in indices { manifest.records[index].deleted = true; manifest.records[index].pendingDeletion = true }
        try save(manifest)
        let report = PhotoTrash.trash(asset, move: move)
        for index in indices where !report.trashed.contains(root.appendingPathComponent(manifest.records[index].stored)) { manifest.records[index].deleted = false }
        for index in indices { manifest.records[index].pendingDeletion = nil }
        try save(manifest)
        return report
    }
}
