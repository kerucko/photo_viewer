import AppKit
import SwiftUI
import Testing
import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct ColumnsNavigationTests {
    struct Fixture {
        let root: URL
        let model: BrowserModel
        var a: URL { root.appendingPathComponent("A") }
        var b: URL { root.appendingPathComponent("B") }
        var nested: URL { a.appendingPathComponent("Nested") }
    }
    private func fixture(catalog: any CatalogSource = FolderCatalog()) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Columns-\(UUID().uuidString)")
        for path in ["A/Nested", "B", "Album.jpg", "Empty"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A/Nested/A very long folder name for testing column truncation"), withIntermediateDirectories: true)
        for (folderIndex, folder) in ["", "A", "A/Nested", "B", "Album.jpg"].enumerated() {
            let names = ["one.jpg", "two.jpg", "three.jpg"] + (folder.isEmpty ? ["z a very long photo filename that must truncate within its column.jpg"] : [])
            for (index, name) in names.enumerated() {
                let width = 60 + folderIndex * 20 + index * 5
                let context = try #require(CGContext(data: nil, width: width, height: 40, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(red: CGFloat(folderIndex + 1) / 6, green: CGFloat(index + 1) / 5, blue: 0.8, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: 40))
                let image = try #require(context.makeImage())
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]))
                try data.write(to: root.appendingPathComponent(folder).appendingPathComponent(name))
            }
        }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("one.raf"))
        let model = BrowserModel(catalog: catalog); model.sort = .name; model.ascending = true
        model.mode = .columns; model.open(root)
        try await wait { !model.loading && model.columns.allSatisfy { !$0.loading } }
        return Fixture(root: try #require(model.folder), model: model)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
    private func column(_ model: BrowserModel, _ url: URL) throws -> BrowserColumn {
        try #require(model.columns.first { $0.id == url.path })
    }
    private func entry(_ model: BrowserModel, _ url: URL, _ name: String) throws -> CatalogEntry {
        try #require(column(model, url).entries.first { $0.name == name })
    }
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    private func settle(_ host: NSView) async {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func table(_ host: NSView, _ url: URL) throws -> ColumnTableView {
        try #require(descendants(host, ColumnTableView.self).first { $0.columnID == url.path })
    }
    private func key(_ code: UInt16, window: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }
    private func click(_ table: ColumnTableView, row: Int, x: CGFloat, window: NSWindow,
                       flags: NSEvent.ModifierFlags = [], count: Int = 1) throws {
        let point = table.convert(NSPoint(x: x, y: table.rect(ofRow: row).midY), to: nil)
        // Resolve through the window's content hierarchy, so cell descendants
        // participate in hit testing. These are synthetic AppKit events.
        let content = try #require(window.contentView)
        let hit = content.hitTest(content.convert(point, from: nil))
        #expect(hit === table)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
    private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_COLUMNS_CAPTURE_DIR"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("columns-\(name).png"))
    }

    @Test func folderNavigationClearsPhotoAndAncestorPhotosCloseBranch() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let model = f.model
        let pair = try entry(model, f.root, "one.jpg")
        #expect(pair.asset?.resources.count == 2)
        model.clickColumn(f.root.path, entryID: pair.id)
        try await wait { !model.previewLoading }
        #expect(model.preview != nil)
        let folder = try entry(model, f.root, "Album.jpg")
        #expect(folder.isFolder)
        model.clickColumn(f.root.path, entryID: folder.id)
        #expect(model.preview == nil && model.previewError == nil)
        #expect(model.selection.ids.isEmpty)
        #expect(model.activeColumnID == f.root.path)
        try await wait { !model.loading }
        #expect(model.entries.count == 3 && model.selection.ids.isEmpty)
        #expect(model.preview == nil && !model.previewLoading)
        // Clicking a photo in an ancestor closes the entire deeper branch.
        model.clickColumn(f.root.path, entryID: pair.id)
        #expect(model.columns.last?.id == f.root.path)
        #expect(model.selection.ids == [pair.id])
        try await wait { !model.previewLoading }
        #expect(model.preview != nil)
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "A").id)
        try await wait { !model.loading }
        model.clickColumn(f.a.path, entryID: try entry(model, f.a, "Nested").id)
        try await wait { !model.loading }
        model.clickColumn(f.root.path, entryID: pair.id)
        #expect(model.columns.last?.id == f.root.path)
        #expect(!model.columns.contains { $0.id == f.a.path || $0.id == f.nested.path })
    }

    @Test func historyHasOneDestinationPerFolderGestureAndRefreshKeepsNoPhoto() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let model = f.model
        let a = try entry(model, f.root, "A"), b = try entry(model, f.root, "B")
        model.clickColumn(f.root.path, entryID: a.id)
        try await wait { !model.loading }
        model.clickColumn(f.root.path, entryID: b.id)
        try await wait { !model.loading }
        model.clickColumn(f.root.path, entryID: b.id, doubleClick: true)
        model.back()
        #expect(model.folder?.path == a.id)
        try await wait { !model.loading }
        model.back()
        #expect(model.folder?.path == f.root.path)
        try await wait { !model.loading }
        model.forward()
        #expect(model.folder?.path == a.id)
        try await wait { !model.loading }
        model.setSort(.name); model.reload()
        try await wait { model.columns.allSatisfy { !$0.loading } }
        #expect(model.selection.ids.isEmpty && model.preview == nil)
        #expect(try column(model, f.a).entries == model.entries)
    }

    @Test func keyboardTraversesAllRowsAndSeparatesFocusFromFolderSelection() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let model = f.model
        model.focusColumn(f.root.path)
        #expect(model.columnKey(125))
        #expect(model.activeColumnID == f.root.path)
        #expect(model.folder?.path == f.a.path && model.selection.ids.isEmpty)
        try await wait { !model.loading }
        #expect(model.columnKey(124))
        #expect(model.activeColumnID == f.a.path)
        #expect(model.selection.ids.isEmpty && model.preview == nil)
        #expect(model.columnKey(126)) // no row selected: Up chooses the last row
        let last = try #require(column(model, f.a).entries.last)
        #expect(model.selection.id == last.id)
        model.columnKey(126)
        let previous = model.selection.id
        model.columnKey(126, shift: true)
        #expect(model.selection.ids.contains(previous!))
        #expect(model.selection.ids.count == 2)
        #expect(model.columnKey(123))
        #expect(model.folder?.path == f.root.path)
        #expect(model.activeColumnID == f.root.path)
        #expect(try column(model, f.root).highlightedID == f.a.path)
        #expect(model.columns.last?.id == f.root.path)
        #expect(model.selection.ids.isEmpty && model.preview == nil)
        model.columnKey(124)
        #expect(model.activeColumnID == f.a.path)
        #expect(model.selection.ids.isEmpty)
        try await wait { !model.loading }
        model.columnKey(125) // first row is Nested, and opens it without moving focus
        #expect(model.activeColumnID == f.a.path)
        #expect(model.folder?.path == f.nested.path)
        #expect(model.selection.ids.isEmpty)
        model.columnKey(125) // next row is a photo in A: closes Nested
        #expect(model.folder?.path == f.a.path)
        #expect(model.selection.id == (try column(model, f.a).entries[1].id))
        model.focusColumn("/")
        let rootLocation = model.location
        model.columnKey(123)
        #expect(model.location == rootLocation) // filesystem root has no parent
    }

    @Test func mouseHitTestingKeyboardAndGroupGalleryAcrossRealColumnTables() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let model = f.model
        let host = NSHostingView(rootView: ColumnBrowser(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        await settle(host)
        for x in [CGFloat(16), 45, 225] { // icon, label, trailing row space
            let parentTable = try table(host, f.root)
            let aRow = try #require(column(model, f.root).entries.firstIndex { $0.name == "A" })
            try click(parentTable, row: aRow, x: x, window: window)
            try await wait { !model.loading }; await settle(host)
            #expect(window.firstResponder === parentTable)
            #expect(model.folder?.path == f.a.path && model.selection.ids.isEmpty)
            #expect(model.preview == nil)
            let childTable = try table(host, f.a)
            let photoRow = try #require(column(model, f.a).entries.firstIndex { !$0.isFolder })
            try click(childTable, row: photoRow, x: x, window: window)
            try await wait { !model.previewLoading }; await settle(host)
            #expect(model.preview != nil && model.selected?.isFolder == false)
            let nestedRow = try #require(column(model, f.a).entries.firstIndex { $0.name == "Nested" })
            try click(childTable, row: nestedRow, x: x, window: window)
            try await wait { !model.loading }; await settle(host)
            #expect(model.folder?.path == f.nested.path && model.preview == nil)
            #expect(window.firstResponder === childTable)
            try click(childTable, row: nestedRow, x: x, window: window, count: 2)
            #expect(model.columns.filter { $0.id == f.nested.path }.count == 1)
            try click(childTable, row: photoRow, x: x, window: window)
            try await wait { !model.previewLoading }; await settle(host)
            #expect(model.folder?.path == f.a.path && model.preview != nil)
            // Ancestor photo must accept the same three hit regions.
            let scroll = try #require(descendants(host, NSScrollView.self).first)
            parentTable.scrollToVisible(parentTable.bounds)
            scroll.reflectScrolledClipView(scroll.contentView); await settle(host)
            let parentPhoto = try #require(column(model, f.root).entries.firstIndex { !$0.isFolder })
            try click(parentTable, row: parentPhoto, x: x, window: window)
            await settle(host)
            #expect(model.folder?.path == f.root.path && model.columns.last?.id == f.root.path)
            #expect(model.selection.id == (try column(model, f.root).entries[parentPhoto].id))
        }
        let parentTable = try table(host, f.root)
        let currentEntries = try column(model, f.root).entries
        let rows = currentEntries.indices.filter { !currentEntries[$0].isFolder }
        try click(parentTable, row: rows[0], x: 225, window: window)
        try click(parentTable, row: rows[1], x: 45, window: window, flags: .command)
        let group = model.selection.ids
        #expect(group.count == 2)
        try click(parentTable, row: rows[1], x: 16, window: window)
        try click(parentTable, row: rows[1], x: 16, window: window, count: 2)
        #expect(model.mode == .gallery && model.selection.ids == group)
        model.toggleGallery(); try await wait { !model.loading }; await settle(host)
        let current = try table(host, f.root)
        window.makeFirstResponder(current)
        try key(126, window: window)
        #expect(model.selection.id == (try column(model, f.root).entries[rows[0]].id))
        // Shift-down ranges use native key dispatch, not direct SelectionState mutation.
        try key(125, window: window, flags: .shift)
        #expect(model.selection.ids.count == 2)
        let captured = model.selection.ids
        let text = NSTextView()
        #expect(!BrowserKeyboard.handle(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 124)), model: model, firstResponder: text))
        #expect(model.selection.ids == captured)
        #expect(!BrowserKeyboard.handle(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 124)), model: model, firstResponder: NSButton()))
        try await wait { !model.previewLoading }; await settle(host)
        try capture(host, name: "photo-1280x800")
        window.setContentSize(NSSize(width: 850, height: 650)); await settle(host)
        try capture(host, name: "photo-850x650")
        window.setContentSize(NSSize(width: 1280, height: 800)); await settle(host)
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "A").id)
        try await wait { !model.loading }; await settle(host)
        try key(124, window: window); await settle(host)
        #expect((window.firstResponder as? ColumnTableView)?.columnID == f.a.path)
        try key(125, window: window)
        try await wait { !model.loading }; await settle(host)
        try capture(host, name: "nested-1280x800")
        window.setContentSize(NSSize(width: 850, height: 650)); await settle(host)
        try capture(host, name: "nested-850x650")
        try key(123, window: window); await settle(host)
        #expect(model.folder?.path == f.root.path && model.columns.last?.id == f.root.path)
        #expect((window.firstResponder as? ColumnTableView)?.columnID == f.root.path)
        #expect(model.selection.ids.isEmpty && model.preview == nil)
    }

    @Test func managedLibraryUsesOneFlatColumnAndRejectsOldFolderLoads() async throws {
        let source = ControlledColumnCatalog()
        let f = try await fixture(catalog: source)
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Library-\(UUID().uuidString)")
        defer { source.release("A"); try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: libraryRoot) }
        let library = PhotoLibrary(root: libraryRoot)
        _ = try await library.importPhotos(from: f.a)
        source.block("A")
        f.model.clickColumn(f.root.path, entryID: try entry(f.model, f.root, "A").id)
        try await wait { source.hasStarted("A") }
        f.model.libraryRoot = libraryRoot; f.model.openLibrary()
        #expect(f.model.loading)
        try await wait { !f.model.loading }
        source.release("A"); try await wait { source.hasFinished("A") }
        #expect(f.model.isLibrary && f.model.ancestors.isEmpty && f.model.columns.isEmpty)
        #expect(f.model.visibleColumns.count == 1)
        #expect(f.model.entries.count == 6 && f.model.entries.allSatisfy { !$0.isFolder })
        f.model.selectAllColumnPhotos(f.model.visibleColumns[0].id)
        #expect(f.model.selection.ids.count == 6)
        f.model.focusColumn(f.model.visibleColumns[0].id)
        let location = f.model.location
        f.model.columnKey(124); f.model.columnKey(123)
        #expect(f.model.location == location && f.model.selection.ids.count == 6)
    }

    @Test func libraryCommandDoubleClickActivatesClickedPhotoAndKeepsPairGroup() async throws {
        let f = try await fixture()
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryDouble-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: libraryRoot) }
        let library = PhotoLibrary(root: libraryRoot)
        _ = try await library.importPhotos(from: f.root)
        let model = f.model
        model.libraryRoot = libraryRoot; model.openLibrary()
        #expect(model.loading, "Opening a library publishes loading before the asynchronous scan starts")
        try await wait { !model.loading }
        let host = NSHostingView(rootView: ColumnBrowser(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        await settle(host)
        let table = try #require(descendants(host, ColumnTableView.self).first)
        let pairIndex = try #require(model.entries.firstIndex { $0.asset?.isPair == true })
        let clickedIndex = try #require(model.entries.firstIndex { !$0.isFolder && $0.asset?.isPair == false })
        let pairID = model.entries[pairIndex].id, clickedID = model.entries[clickedIndex].id
        table.scrollRowToVisible(pairIndex); await settle(host)
        try click(table, row: pairIndex, x: 45, window: window)
        table.scrollRowToVisible(clickedIndex); await settle(host)
        try click(table, row: clickedIndex, x: 225, window: window, flags: .command)
        #expect(model.selection.ids == [pairID, clickedID])
        try click(table, row: clickedIndex, x: 225, window: window, flags: .command, count: 2)
        #expect(model.mode == .gallery && model.selection.id == clickedID)
        #expect(model.selection.ids == [pairID, clickedID])
        #expect(model.selectedAssets.count == 2 && model.selectedAssets.flatMap(\.resources).count == 3)
    }

    @Test func obsoleteCatalogAndPreviewCannotRepopulateAnotherBranch() async throws {
        let source = ControlledColumnCatalog()
        let f = try await fixture(catalog: source); defer { source.release("A"); try? FileManager.default.removeItem(at: f.root) }
        let model = f.model
        source.block("A")
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "one.jpg").id)
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "A").id)
        try await wait { source.hasStarted("A") }
        #expect(model.preview == nil && model.selection.ids.isEmpty)
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "B").id)
        try await wait { !model.loading }
        let newest = try #require(model.photos.last)
        model.clickColumn(f.b.path, entryID: newest.id)
        try await wait { !model.previewLoading }
        let newestImage = model.preview?.cgImage
        #expect(newestImage?.width == 125)
        source.release("A")
        try await wait { source.hasFinished("A") }
        for _ in 0..<30 { await Task.yield() }
        #expect(model.folder?.path == f.b.path)
        #expect(model.entries.allSatisfy { $0.url.deletingLastPathComponent().path == f.b.path })
        #expect(model.selection.id == newest.id && model.preview?.cgImage === newestImage)
        #expect(!model.columns.contains { $0.id == f.a.path })
    }

    @Test func historyAndModeSwitchCancelPendingCatalogAndSortUsesLatestOrder() async throws {
        let source = ControlledColumnCatalog()
        let f = try await fixture(catalog: source); defer { source.release("A"); try? FileManager.default.removeItem(at: f.root) }
        let model = f.model
        source.block("A")
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "A").id)
        try await wait { source.hasStarted("A") }
        model.back()
        try await wait { !model.loading }
        source.release("A")
        try await wait { source.hasFinished("A") }
        #expect(model.folder?.path == f.root.path && model.selection.ids.isEmpty)
        source.block("A")
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "A").id)
        try await wait { source.hasStarted("A") }
        model.setSort(.name)
        model.mode = .icons
        #expect(model.columns.isEmpty)
        source.release("A")
        try await wait { !model.loading }
        #expect(model.mode == .icons && model.folder?.path == f.a.path)
        #expect(model.entries.map(\.name) == FolderCatalog.sorted(try FolderCatalog().contents(of: f.a), by: .name, ascending: false).map(\.name))
        #expect(model.selection.ids.isEmpty && model.preview == nil)
    }

    @Test func emptyErrorAndMissingChildRemainNavigableWithoutOldPreview() async throws {
        let source = ControlledColumnCatalog()
        let f = try await fixture(catalog: source); defer { try? FileManager.default.removeItem(at: f.root) }
        let model = f.model
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "Empty").id)
        try await wait { !model.loading }
        #expect(model.entries.isEmpty && model.columns.last?.error == nil)
        #expect(model.selection.ids.isEmpty && model.preview == nil)
        source.fail("B")
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "B").id)
        try await wait { !model.loading }
        #expect(model.columns.last?.error != nil && model.columns.last?.entries.isEmpty == true)
        #expect(model.error == nil && model.preview == nil && model.selection.ids.isEmpty)
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "one.jpg").id)
        try await wait { !model.previewLoading }
        #expect(model.preview != nil && model.columns.last?.id == f.root.path)
        model.clickColumn(f.root.path, entryID: try entry(model, f.root, "A").id)
        try await wait { !model.loading }
        model.clickColumn(f.a.path, entryID: try entry(model, f.a, "Nested").id)
        try await wait { !model.loading }
        try FileManager.default.removeItem(at: f.nested)
        model.reload()
        try await wait { model.columns.allSatisfy { !$0.loading } }
        #expect(model.folder?.path == f.a.path && model.columns.last?.id == f.a.path)
        #expect(model.selection.ids.isEmpty && model.preview == nil)
    }

}


/// Delays specific directory reads on the catalog worker, without blocking the
/// main actor, so tests can release a removed branch after its replacement loads.
private final class ControlledColumnCatalog: CatalogSource, @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: Set<String> = []
    private var started: Set<String> = []
    private var finished: Set<String> = []
    private var failures: Set<String> = []
    func block(_ name: String) {
        condition.lock(); defer { condition.unlock() }
        blocked.insert(name); started.remove(name); finished.remove(name)
    }
    func release(_ name: String) {
        condition.lock(); defer { condition.unlock() }
        blocked.remove(name); condition.broadcast()
    }
    func fail(_ name: String) { condition.lock(); failures.insert(name); condition.unlock() }
    func hasStarted(_ name: String) -> Bool { condition.lock(); defer { condition.unlock() }; return started.contains(name) }
    func hasFinished(_ name: String) -> Bool { condition.lock(); defer { condition.unlock() }; return finished.contains(name) }
    func contents(of folder: URL) throws -> [CatalogEntry] {
        let name = folder.lastPathComponent
        condition.lock()
        started.insert(name)
        while blocked.contains(name) { condition.wait() }
        let fails = failures.contains(name)
        condition.unlock()
        defer { condition.lock(); finished.insert(name); condition.unlock() }
        if fails { throw CocoaError(.fileReadNoPermission) }
        return try FolderCatalog().contents(of: folder)
    }
}
