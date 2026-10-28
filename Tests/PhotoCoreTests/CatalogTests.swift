import Foundation
import Testing
@testable import PhotoCore

struct CatalogTests {
    func resource(_ path: String, size: Int64 = 10, date: Double = 0) -> PhotoResource {
        PhotoResource(url: URL(fileURLWithPath: path), size: size, modified: Date(timeIntervalSince1970: date))
    }
    @Test func testPairsAndStandalone() {
        let assets = FolderCatalog.pair([resource("/a/DSC.JPG", size: 20, date: 1), resource("/a/DSC.RaF", size: 30, date: 2), resource("/a/solo.raf")])
        expectEqual(assets.count, 2)
        let pair = assets.first { $0.isPair }!
        expectEqual(pair.size, 50); expectEqual(pair.modified, Date(timeIntervalSince1970: 2))
        expectEqual(pair.preferred.url.pathExtension, "JPG")
    }
    @Test func testFoldersAndStemCaseRemainSeparate() {
        let assets = FolderCatalog.pair([resource("/a/P.jpg"), resource("/b/P.raf"), resource("/a/p.raf")])
        expectEqual(assets.count, 3); expectFalse(assets.contains { $0.isPair })
    }
    @Test func testAmbiguousJPEGDeterministic() {
        let files = [resource("/a/P.jpeg"), resource("/a/P.jpg"), resource("/a/P.JPG"), resource("/a/P.raf")]
        let assets = FolderCatalog.pair(files)
        expectEqual(assets.count, 3)
        expectEqual(assets.first { $0.isPair }?.jpeg?.url.lastPathComponent, "P.JPG")
        expectEqual(assets, FolderCatalog.pair(files.reversed()))
    }
    @Test func testNaturalOrderFoldersFirst() {
        let assets = FolderCatalog.pair([resource("/a/10.jpg"), resource("/a/2.jpg")])
        let entries = assets.map { CatalogEntry(url: $0.preferred.url, asset: $0) } + [CatalogEntry(url: URL(fileURLWithPath: "/a/z"))]
        expectEqual(FolderCatalog.sorted(entries).map(\.name), ["z", "2.jpg", "10.jpg"])
        expectEqual(FolderCatalog.sorted(entries, ascending: false).map(\.name), ["z", "10.jpg", "2.jpg"])
    }
    @Test func testLargeCatalog() {
        let resources = (0..<5000).flatMap { index in
            [resource("/large/DSC_\(index).jpg"), resource("/large/DSC_\(index).raf")]
        }
        let assets = FolderCatalog.pair(resources)
        expectEqual(assets.count, 5000)
        expectTrue(assets.allSatisfy(\.isPair))
        let entries = FolderCatalog.sorted(assets.map { CatalogEntry(url: $0.preferred.url, asset: $0) })
        expectEqual(entries.first?.name, "DSC_0.jpg")
        expectEqual(entries.last?.name, "DSC_4999.jpg")
    }
    @Test func testSelectionAndStaleRequest() {
        var state = SelectionState(); state.select("a"); let old = state.revision
        state.toggleRAW(); expectTrue(state.showsRAW); expectFalse(state.accepts(old))
        state.mode = .gallery; expectEqual(state.id, "a"); expectTrue(state.showsRAW)
        let current = state.revision; state.select("a"); expectTrue(state.accepts(current))
        state.select("b"); expectFalse(state.showsRAW); expectFalse(state.accepts(current))
    }
    @Test func testFolderScanIsReadOnlyAndNonRecursive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3])
        for name in ["a.jpg", "a.raf", "ignore.png", ".hidden.jpg"] { try bytes.write(to: root.appendingPathComponent(name)) }
        try bytes.write(to: sub.appendingPathComponent("nested.jpg"))
        let entries = try FolderCatalog().contents(of: root)
        expectEqual(entries.count, 2); expectTrue(entries[0].isFolder); expectTrue(entries[1].asset!.isPair)
        expectEqual(try Data(contentsOf: root.appendingPathComponent("a.raf")), bytes)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}
private func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, sourceLocation: sourceLocation)
}

struct ResourceGenerationTests {
    @Test func catalogGenerationChangesOnlyAfterActualFileChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("one.jpg")
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try Data("first".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let before = try #require(FolderCatalog().contents(of: folder).first?.asset)
        #expect(try FolderCatalog().contents(of: folder).first?.asset == before)
        try Data("other".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let after = try #require(FolderCatalog().contents(of: folder).first?.asset)
        #expect(before.id == after.id); #expect(before.size == after.size); #expect(before.modified == after.modified)
        #expect(before != after)
        #expect(before.preferred.fileGeneration != after.preferred.fileGeneration)
        #expect(try FolderCatalog().contents(of: folder).first?.asset == after)
    }
}
