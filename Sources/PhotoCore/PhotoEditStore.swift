import Foundation
import CryptoKit
import Darwin

public struct PhotoEditToken: Sendable {
    fileprivate let resources: [EditResource]
    fileprivate let storeDigest: String
}
public struct PhotoEditRecipe: Sendable {
    public let edit: PhotoEdit
    public let warning: String?
}
public struct PhotoEditLoad: Sendable {
    public let edit: PhotoEdit
    public let warning: String?
    public let token: PhotoEditToken
}
private struct EditFingerprint: Codable, Hashable, Sendable {
    let size: UInt64
    let modified: Double
    let digest: String
    let identity: String
    func matches(_ other: Self, portable: Bool) -> Bool {
        size == other.size && modified == other.modified && digest == other.digest && (portable || identity == other.identity)
    }
}
private struct EditResource: Codable, Hashable, Sendable {
    let path: String
    let fingerprint: EditFingerprint
}

/// Recipe persistence is independent of catalog IDs. Library paths are relative
/// to the library root; ordinary folders never receive files next to originals.
public actor PhotoEditStore {
    public nonisolated let storageURL: URL
    private let root: URL
    private let portable: Bool
    private let writer: @Sendable (Data, URL) throws -> Void
    private var fingerprints: [String: (String, EditFingerprint)] = [:]
    private struct Record: Codable {
        let id: UUID
        var resources: [EditResource]
        var edit: PhotoEdit
    }
    private var documentCache: (key: String, document: Document, digest: String)?
    private struct Document: Codable {
        var version = 1
        var records: [Record] = []
    }
    public init(folder: URL, libraryRoot: URL? = nil, storageURL: URL? = nil,
                writer: (@Sendable (Data, URL) throws -> Void)? = nil) {
        let canonicalRoot = (libraryRoot ?? folder).resolvingSymlinksInPath().standardizedFileURL
        root = canonicalRoot
        portable = libraryRoot != nil
        if let storageURL { self.storageURL = storageURL }
        else if libraryRoot != nil { self.storageURL = canonicalRoot.appendingPathComponent("edits.json") }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageURL = support.appendingPathComponent("PhotoViewer/Edits", isDirectory: true)
                .appendingPathComponent(Self.digest(Data(canonicalRoot.path.utf8)) + ".json")
        }
        self.writer = writer ?? { data, url in try data.write(to: url, options: .atomic) }
    }
    /// Catalog lookup never reads the bytes of an unedited resource. An editor
    /// uses load(for:) instead to capture a complete optimistic save token.
    public func recipe(for asset: PhotoAsset) throws -> PhotoEditRecipe {
        let (document, _) = try read()
        guard !document.records.isEmpty else { return PhotoEditRecipe(edit: .identity, warning: nil) }
        let paths = Set(try asset.resources.map { try relativePath($0.url) })
        if document.records.contains(where: { record in record.resources.contains { paths.contains($0.path) } }) {
            let result = try load(for: asset)
            return PhotoEditRecipe(edit: result.edit, warning: result.warning)
        }
        let identities = asset.resources.compactMap { resource -> String? in
            var information = stat()
            guard lstat(resource.url.path, &information) == 0 else { return nil }
            return "\(information.st_dev):\(information.st_ino)"
        }
        let renamed = document.records.contains { record in
            record.resources.contains { identities.contains($0.fingerprint.identity) }
        }
        return PhotoEditRecipe(edit: .identity, warning: renamed ? "Снимок переименован или перемещён. Старые правки не перенесены; сохраните их заново." : nil)
    }
    public func load(for asset: PhotoAsset) throws -> PhotoEditLoad {
        let (document, digest) = try read()
        let current = try capture(asset)
        let currentPaths = Set(current.map(\.path))
        let candidates = document.records.filter { !$0.resources.allSatisfy { !currentPaths.contains($0.path) } }
        let token = PhotoEditToken(resources: current, storeDigest: digest)
        guard candidates.count <= 1 else {
            return PhotoEditLoad(edit: .identity, warning: "У ресурсов пары разные сохранённые правки. Сохраните общий вариант заново.", token: token)
        }
        if let record = candidates.first {
            let allKnown = current.allSatisfy { resource in
                record.resources.contains { $0.path == resource.path && $0.fingerprint.matches(resource.fingerprint, portable: portable) }
            }
            // Also inspect a known companion that still exists even if catalog
            // membership changed. A replaced RAW cannot inherit a JPEG's recipe.
            var existingKnownUnchanged = true
            for known in record.resources where !currentPaths.contains(known.path) {
                let url = root.appendingPathComponent(known.path)
                if FileManager.default.fileExists(atPath: url.path) {
                    guard let fresh = try? fingerprint(url), known.fingerprint.matches(fresh, portable: portable) else {
                        existingKnownUnchanged = false; break
                    }
                }
            }
            guard allKnown && existingKnownUnchanged else {
                return PhotoEditLoad(edit: .identity, warning: "Ресурсы снимка или состав пары изменились. Показан оригинал; сохраните правки заново.", token: token)
            }
            return PhotoEditLoad(edit: record.edit, warning: nil, token: token)
        }
        // A rename is never silently rebound. Matching content is only a hint
        // for an explicit warning, not a new recipe identity.
        let renamed = document.records.contains { record in
            record.resources.contains { known in current.contains { $0.fingerprint.digest == known.fingerprint.digest } }
        }
        return PhotoEditLoad(edit: .identity, warning: renamed ? "Снимок переименован или перемещён. Старые правки не перенесены; сохраните их заново." : nil, token: token)
    }
    public func save(_ edit: PhotoEdit, for asset: PhotoAsset, token: PhotoEditToken) throws {
        guard edit.isValid else { throw PhotoEditError.invalidRecipe }
        var (document, digest) = try read()
        guard digest == token.storeDigest else { throw PhotoEditError.changedStore }
        let current = try capture(asset)
        guard current == token.resources else { throw PhotoEditError.changedResources }
        let paths = Set(current.map(\.path))
        let matched = document.records.filter { record in record.resources.contains { paths.contains($0.path) } }
        // Preserve aliases for absent members, but never retain a second recipe
        // for an explicitly resolved merge or stale current resource.
        var resources = current
        for record in matched {
            for known in record.resources where !paths.contains(known.path)
                && !FileManager.default.fileExists(atPath: root.appendingPathComponent(known.path).path) {
                if !resources.contains(where: { $0.path == known.path }) { resources.append(known) }
            }
        }
        document.records.removeAll { record in record.resources.contains { paths.contains($0.path) } }
        document.records.append(Record(id: matched.first?.id ?? UUID(), resources: resources.sorted { $0.path < $1.path }, edit: edit))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Writer is injectable to exercise disk errors without touching originals.
        // The default uses an atomic sibling-file replacement.
        try writer(data, storageURL)
    }
    private func read() throws -> (Document, String) {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return (Document(), "missing") }
        var information = stat()
        guard lstat(storageURL.path, &information) == 0, information.st_mode & S_IFMT == S_IFREG else { throw PhotoEditError.invalidStore }
        let cacheKey = "\(information.st_dev):\(information.st_ino):\(information.st_size):\(information.st_mtimespec.tv_sec):\(information.st_mtimespec.tv_nsec):\(information.st_ctimespec.tv_sec):\(information.st_ctimespec.tv_nsec)"
        if let cached = documentCache, cached.key == cacheKey { return (cached.document, cached.digest) }
        let data = try Data(contentsOf: storageURL)
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1,
              document.records.allSatisfy({ record in
                  record.edit.isValid && !record.resources.isEmpty && Set(record.resources.map(\.path)).count == record.resources.count
                    && record.resources.allSatisfy { validRelative($0.path) }
              }) else { throw PhotoEditError.invalidStore }
        let digest = Self.digest(data)
        documentCache = (cacheKey, document, digest)
        return (document, digest)
    }
    private func capture(_ asset: PhotoAsset) throws -> [EditResource] {
        try asset.resources.map { resource in
            let url = resource.url.standardizedFileURL
            let path = try relativePath(url)
            return EditResource(path: path, fingerprint: try fingerprint(url))
        }.sorted { $0.path < $1.path }
    }
    private func relativePath(_ url: URL) throws -> String {
        let original = url.standardizedFileURL
        var info = stat()
        if lstat(original.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw PhotoEditError.outsideRoot }
        // Resolve directory aliases, including macOS /var -> /private/var, while
        // rejecting a photo file that is itself a symlink above.
        let url = original.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(original.lastPathComponent).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { throw PhotoEditError.outsideRoot }
        let path = String(url.path.dropFirst(prefix.count))
        guard validRelative(path) else { throw PhotoEditError.outsideRoot }
        return path
    }
    private func validRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
    private func fingerprint(_ url: URL) throws -> EditFingerprint {
        var information = stat()
        guard lstat(url.path, &information) == 0, information.st_mode & S_IFMT == S_IFREG else { throw PhotoEditError.changedResources }
        let identity = "\(information.st_dev):\(information.st_ino)"
        let cacheKey = "\(identity):\(information.st_size):\(information.st_mtimespec.tv_sec):\(information.st_mtimespec.tv_nsec):\(information.st_ctimespec.tv_sec):\(information.st_ctimespec.tv_nsec)"
        if let (key, cached) = fingerprints[url.path], key == cacheKey { return cached }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        var after = stat()
        guard lstat(url.path, &after) == 0, information.st_ino == after.st_ino, information.st_dev == after.st_dev,
              information.st_size == after.st_size, information.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              information.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, information.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              information.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw PhotoEditError.changedResources }
        let value = EditFingerprint(size: UInt64(information.st_size),
            modified: Double(information.st_mtimespec.tv_sec) + Double(information.st_mtimespec.tv_nsec) / 1_000_000_000,
            digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), identity: identity)
        fingerprints[url.path] = (cacheKey, value)
        return value
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
