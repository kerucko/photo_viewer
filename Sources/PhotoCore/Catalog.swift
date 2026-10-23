import Foundation

public struct PhotoResource: Hashable, Sendable {
    public let url: URL
    public let size: Int64
    public let modified: Date
    public var isRAW: Bool { url.pathExtension.lowercased() == "raf" }
    public init(url: URL, size: Int64 = 0, modified: Date = .distantPast) {
        self.url = url; self.size = size; self.modified = modified
    }
}

public struct PhotoAsset: Identifiable, Hashable, Sendable {
    public let resources: [PhotoResource]
    public var id: String { resources[0].url.path }
    public var name: String { resources[0].url.lastPathComponent }
    public var jpeg: PhotoResource? { resources.first { !$0.isRAW } }
    public var raw: PhotoResource? { resources.first { $0.isRAW } }
    public var preferred: PhotoResource { jpeg ?? resources[0] }
    public var isPair: Bool { jpeg != nil && raw != nil }
    public var kind: String { isPair ? "JPG + RAW" : (raw != nil ? "RAW" : "JPG") }
    public var size: Int64 { resources.reduce(0) { $0 + $1.size } }
    public var modified: Date { resources.map(\.modified).max() ?? .distantPast }
    public init(resources: [PhotoResource]) { precondition(!resources.isEmpty); self.resources = resources }
}

public struct CatalogEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let asset: PhotoAsset?
    public var id: String { asset?.id ?? url.path }
    public var name: String { asset?.name ?? url.lastPathComponent }
    public var isFolder: Bool { asset == nil }
    public var kind: String { asset?.kind ?? "Папка" }
    public var size: Int64 { asset?.size ?? 0 }
    public var modified: Date { asset?.modified ?? .distantPast }
    public init(url: URL, asset: PhotoAsset? = nil) { self.url = url; self.asset = asset }
}

public enum CatalogSort: String, CaseIterable, Sendable { case name, kind, modified, size }
public enum ViewMode: String, CaseIterable, Sendable { case icons, list, columns, gallery }

public protocol CatalogSource: Sendable {
    func contents(of folder: URL) throws -> [CatalogEntry]
}

public struct FolderCatalog: CatalogSource {
    public init() {}
    public func contents(of folder: URL) throws -> [CatalogEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var folders: [CatalogEntry] = [], resources: [PhotoResource] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true { folders.append(CatalogEntry(url: url)); continue }
            guard values.isRegularFile == true, ["jpg", "jpeg", "raf"].contains(url.pathExtension.lowercased()) else { continue }
            resources.append(PhotoResource(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        return Self.sorted(folders + Self.pair(resources).map { CatalogEntry(url: $0.preferred.url, asset: $0) })
    }
    public static func pair(_ resources: [PhotoResource]) -> [PhotoAsset] {
        let groups = Dictionary(grouping: resources) { $0.url.deletingPathExtension().path }
        return groups.keys.sorted().flatMap { key -> [PhotoAsset] in
            let items = groups[key]!.sorted {
                func rank(_ r: PhotoResource) -> Int { r.isRAW ? 2 : (r.url.pathExtension.lowercased() == "jpg" ? 0 : 1) }
                return rank($0) == rank($1) ? $0.url.lastPathComponent < $1.url.lastPathComponent : rank($0) < rank($1)
            }
            let jpg = items.first { !$0.isRAW }, raw = items.first { $0.isRAW }
            if let jpg, let raw {
                return [PhotoAsset(resources: [jpg, raw])] + items.filter { $0 != jpg && $0 != raw }.map { PhotoAsset(resources: [$0]) }
            }
            return items.map { PhotoAsset(resources: [$0]) }
        }
    }
    public static func sorted(_ entries: [CatalogEntry], by sort: CatalogSort = .name, ascending: Bool = true) -> [CatalogEntry] {
        entries.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            let order: ComparisonResult
            switch sort {
            case .name: order = $0.name.localizedStandardCompare($1.name)
            case .kind: order = $0.kind.compare($1.kind)
            case .size: order = $0.size == $1.size ? .orderedSame : ($0.size < $1.size ? .orderedAscending : .orderedDescending)
            case .modified: order = $0.modified == $1.modified ? .orderedSame : ($0.modified < $1.modified ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame { return $0.id < $1.id }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

/// Selection belongs to an asset, not a particular resource or view mode.
public struct SelectionState: Sendable {
    public private(set) var id: String?
    public private(set) var ids: Set<String> = []
    public private(set) var anchorID: String?
    public private(set) var showsRAW = false
    public private(set) var revision: UInt64 = 0
    public var mode: ViewMode = .icons
    public init() {}

    private mutating func setPrimary(_ id: String?) {
        guard self.id != id else { return }
        self.id = id; showsRAW = false; revision &+= 1
    }
    public mutating func select(_ id: String?) {
        ids = id.map { [$0] } ?? []; anchorID = id; setPrimary(id)
    }
    public mutating func replace(_ ids: Set<String>, primary: String?, orderedIDs: [String]) {
        self.ids = ids.intersection(orderedIDs)
        let primary = primary.flatMap { self.ids.contains($0) ? $0 : nil }
            ?? id.flatMap { self.ids.contains($0) ? $0 : nil }
            ?? orderedIDs.first { self.ids.contains($0) }
        setPrimary(primary); anchorID = primary
    }
    public mutating func focus(_ id: String) {
        guard ids.contains(id) else { select(id); return }
        setPrimary(id)
    }
    public mutating func toggle(_ id: String, orderedIDs: [String]) {
        if ids.remove(id) != nil {
            if self.id == id { setPrimary(orderedIDs.first { ids.contains($0) }) }
        }
        else { ids.insert(id); setPrimary(id) }
        anchorID = id
    }
    public mutating func extend(to id: String, orderedIDs: [String]) {
        guard let end = orderedIDs.firstIndex(of: id) else { return }
        let anchor = anchorID.flatMap { orderedIDs.firstIndex(of: $0) }
            ?? self.id.flatMap { orderedIDs.firstIndex(of: $0) } ?? end
        anchorID = orderedIDs[anchor]
        ids = Set(orderedIDs[min(anchor, end)...max(anchor, end)])
        setPrimary(id)
    }
    public mutating func retain(orderedIDs: [String]) {
        ids.formIntersection(orderedIDs)
        if let id, !ids.contains(id) { setPrimary(orderedIDs.first { ids.contains($0) }) }
        if let anchorID, !orderedIDs.contains(anchorID) { self.anchorID = id }
    }
    public mutating func toggleRAW() { showsRAW.toggle(); revision &+= 1 }
    public func accepts(_ request: UInt64) -> Bool { revision == request }
}
