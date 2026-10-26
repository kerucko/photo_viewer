import AppKit
import Testing
import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct ColumnsBusyRegressionTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    @Test func pendingAncestorRefreshCannotChangeCatalogDuringZIPSession() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ColumnsBusy-\(UUID().uuidString)")
        let child = root.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let photo = child.appendingPathComponent("photo.jpg")
        // Image validity is irrelevant to this catalog-only regression; no ZIP is exported.
        try Data().write(to: photo)
        let source = BusyAncestorCatalog(root: root, child: child)
        let model = BrowserModel(catalog: source)
        defer {
            source.release()
            model.zipSession?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        model.mode = .columns; model.open(root)
        try await wait { !model.loading && model.columns.allSatisfy { !$0.loading } }
        model.clickColumn(root.path, entryID: child.path)
        try await wait { !model.loading && model.columns.allSatisfy { !$0.loading } }
        model.clickColumn(child.path, entryID: photo.path)
        try await wait { !model.previewLoading }
        source.blockAncestor()
        model.reload()
        try await wait { source.started && !model.loading }
        let location = model.location
        let entries = model.entries
        let selected = model.selection.ids
        let primary = model.selection.id
        let branch = model.columns.map(\.id)
        model.createZIP()
        let session = try #require(model.zipSession)
        #expect(model.busy)
        #expect(session.location == location)
        #expect(session.resources == [photo])
        // Simulate a catalog refresh discovering that its selected child vanished.
        // The synthetic file itself is left in place throughout this test.
        source.hideChildAndRelease()
        try await wait { source.finished }
        for _ in 0..<30 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(model.busy)
        #expect(model.location == location)
        #expect(model.entries == entries)
        #expect(model.selection.ids == selected && model.selection.id == primary)
        #expect(model.columns.map(\.id) == branch)
        #expect(session.resources == [photo])
        // Closing the unstarted session creates no archive and releases busy.
        session.cancel()
        #expect(!model.busy && model.zipSession == nil)
        model.reload()
        try await wait { model.columns.allSatisfy { !$0.loading } }
        #expect(model.folder?.path == root.path)
        #expect(model.columns.last?.id == root.path)
        #expect(model.entries.isEmpty && model.selection.ids.isEmpty)
        #expect(model.preview == nil)
        #expect(FileManager.default.fileExists(atPath: photo.path))
    }

    @Test func closingZIPResumesAnUnfilledAncestorWithoutManualReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ColumnsResume-\(UUID().uuidString)")
        let child = root.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let photo = child.appendingPathComponent("photo.jpg")
        try Data().write(to: photo)
        let source = BusyAncestorCatalog(root: root, child: child)
        source.blockAncestor()
        let model = BrowserModel(catalog: source)
        defer { source.release(); model.zipSession?.cancel(); try? FileManager.default.removeItem(at: root) }
        model.mode = .columns; model.open(child)
        try await wait { source.started && !model.loading }
        model.clickColumn(child.path, entryID: photo.path)
        model.createZIP()
        let session = try #require(model.zipSession)
        #expect(model.columns.first { $0.id == root.path }?.entries.isEmpty == true)
        #expect(model.columns.allSatisfy { !$0.loading })
        session.cancel()
        #expect(!model.busy)
        #expect(model.columns.first { $0.id == root.path }?.loading == true)
        source.release()
        try await wait { model.columns.allSatisfy { !$0.loading } }
        #expect(model.columns.first { $0.id == root.path }?.entries.contains { $0.id == child.path } == true)
        #expect(model.folder?.path == child.path && model.selection.ids == [photo.path])
    }

}

private final class BusyAncestorCatalog: CatalogSource, @unchecked Sendable {
    private let root: URL
    private let child: URL
    private let condition = NSCondition()
    private var blocked = false
    private var hidden = false
    private var didStart = false
    private var didFinish = false
    init(root: URL, child: URL) { self.root = root; self.child = child }
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    var finished: Bool { condition.lock(); defer { condition.unlock() }; return didFinish }
    func blockAncestor() {
        condition.lock(); defer { condition.unlock() }
        blocked = true; didStart = false; didFinish = false
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        blocked = false; condition.broadcast()
    }
    func hideChildAndRelease() {
        condition.lock(); defer { condition.unlock() }
        hidden = true; blocked = false; condition.broadcast()
    }
    func contents(of folder: URL) throws -> [CatalogEntry] {
        guard folder.path == root.path else { return try FolderCatalog().contents(of: folder) }
        condition.lock()
        if blocked { didStart = true }
        while blocked { condition.wait() }
        let omitChild = hidden
        condition.unlock()
        defer { condition.lock(); didFinish = true; condition.unlock() }
        let entries = try FolderCatalog().contents(of: folder)
        return omitChild ? entries.filter { $0.url.lastPathComponent != child.lastPathComponent } : entries
    }
}
