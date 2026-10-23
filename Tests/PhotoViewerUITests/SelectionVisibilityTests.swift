import AppKit
import SwiftUI
import Testing
import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct SelectionVisibilityTests {
    private func model() -> BrowserModel {
        let model = BrowserModel()
        model.entries = (0..<200).map {
            CatalogEntry(url: URL(fileURLWithPath: String(format: "/synthetic/Photo-%03d", $0)))
        }
        return model
    }

    func photoFixture() async throws -> (model: BrowserModel, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8,
            bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        context.setFillColor(CGColor(red: 0.95, green: 0.65, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 24, height: 16))
        let image = try #require(context.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]))
        let model = BrowserModel()
        model.entries = try (0..<200).map { index in
            let url = directory.appendingPathComponent(String(format: "Photo-%03d.jpg", index))
            try data.write(to: url)
            return CatalogEntry(url: url, asset: PhotoAsset(resources: [PhotoResource(url: url)]))
        }
        // Preload real decoded synthetic pixels so captures don't depend on
        // background thumbnail timing. No fixture or render enters the repo.
        for entry in model.entries { _ = try await ImageService.shared.image(entry.asset!.preferred, maxPixel: 480) }
        model.preview = try await ImageService.shared.image(model.entries[0].asset!.preferred, maxPixel: nil)
        return (model, directory)
    }

    private func content(_ model: BrowserModel) -> AnyView {
        switch model.mode {
        case .icons: AnyView(IconGrid(model: model))
        case .list: AnyView(FileTable(model: model))
        case .columns: AnyView(ColumnBrowser(model: model))
        case .gallery: AnyView(GalleryView(model: model))
        }
    }

    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }

    private func settle(_ host: NSView) async {
        // Drain UI transactions, not a wall-clock delay. Layout each turn so
        // requests queued during SwiftUI reconciliation can reach AppKit.
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test func nativeViewsRevealSelectionAfterLayoutAndRespectManualScroll() async throws {
        let model = model()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        for mode in [ViewMode.icons, .list] {
            for selected in [0, 100, 199] {
                model.mode = mode
                model.selection.select(model.entries[selected].id)
                let host = NSHostingView(rootView: content(model))
                host.frame = NSRect(x: 0, y: 0, width: 850, height: 650)
                host.layoutSubtreeIfNeeded() // Requests survive layout before attachment.
                window.contentView = host
                await settle(host)
                let scroll = try #require(descendants(host, SelectionScrollView.self).first)
                if mode == .icons {
                    let collection = try #require(scroll.documentView as? NSCollectionView)
                    let frame = try #require(collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: selected, section: 0))?.frame)
                    #expect(collection.visibleRect.insetBy(dx: -1, dy: -1).contains(frame))
                } else {
                    let table = try #require(scroll.documentView as? NSTableView)
                    #expect(table.rows(in: table.visibleRect).contains(selected))
                    let frame = table.rect(ofRow: selected)
                    #expect(frame.minY >= table.visibleRect.minY - 1)
                    #expect(frame.maxY <= table.visibleRect.maxY + 1)
                }
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                let manualOrigin = scroll.contentView.bounds.origin
                model.previewError = "Synthetic preview update"
                host.rootView = content(model)
                await settle(host)
                #expect(scroll.contentView.bounds.origin == manualOrigin)
            }
        }
    }

    @Test func allViewTransitionsPreserveSelectionAndCaptureFinalViews() async throws {
        let fixture = try await photoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let modes: [ViewMode] = [.icons, .list, .columns, .gallery]
        for source in modes {
            for destination in modes where destination != source {
                for selected in [0, 100, 199] {
                    model.mode = source
                    model.selection.select(model.entries[selected].id)
                    let host = NSHostingView(rootView: content(model))
                    window.contentView = host
                    await settle(host)
                    model.mode = destination
                    host.rootView = content(model)
                    await settle(host)
                    #expect(model.selection.id == model.entries[selected].id)
                    try expectVisible(host, model: model, selected: selected)
                    if source == .icons, selected == 100 { try capture(host, name: destination.rawValue) }
                }
            }
        }
        model.mode = .icons
        let host = NSHostingView(rootView: content(model))
        window.contentView = host
        await settle(host)
        try capture(host, name: "icons")
    }

    @Test func selectionChangesReorderingAndEmptyCatalog() async throws {
        let model = model()
        let original = model.entries
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        for mode in [ViewMode.icons, .list, .columns, .gallery] {
            model.entries = original
            model.mode = mode
            model.selection.select(original[0].id)
            let host = NSHostingView(rootView: content(model))
            window.contentView = host
            await settle(host)
            model.selection.select(original[199].id)
            host.rootView = content(model)
            await settle(host)
            try expectVisible(host, model: model, selected: 199)
            model.entries.reverse()
            host.rootView = content(model)
            await settle(host)
            try expectVisible(host, model: model, selected: 0)
            // Repeated updates before layout must reveal only the newest ID.
            model.selection.select(original[0].id)
            host.rootView = content(model)
            model.selection.select(original[100].id)
            host.rootView = content(model)
            await settle(host)
            try expectVisible(host, model: model, selected: 99)
            let scrolls = descendants(host, NSScrollView.self)
            let scroll = try #require(mode == .columns ? scrolls.last : scrolls.first)
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let origin = scroll.contentView.bounds.origin
            model.previewError = "Another synthetic update"
            host.rootView = content(model)
            await settle(host)
            #expect(scroll.contentView.bounds.origin == origin)
            model.selection.select(nil)
            model.entries = []
            host.rootView = content(model)
            await settle(host)
            #expect(model.selection.id == nil)
        }
    }

    @Test func photoCommandsSizesAndUnselectedCatalog() async throws {
        let fixture = try await photoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        let savedIconSize = model.iconSize
        let savedFilmstripSize = model.filmstripSize
        defer { model.iconSize = savedIconSize; model.filmstripSize = savedFilmstripSize }
        let entry = model.entries[100]
        // A synthetic pair tests state preservation only; no fake RAW is decoded.
        model.entries[100] = CatalogEntry(url: entry.url, asset: PhotoAsset(resources: [
            entry.asset!.preferred, PhotoResource(url: entry.url.deletingPathExtension().appendingPathExtension("raf"))]))
        model.selection.select(entry.id)
        model.selection.toggleRAW()
        let viewport = ViewportState(scale: 2, offset: CGSize(width: 31, height: -17))
        model.viewport = viewport
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        for mode in [ViewMode.icons, .list, .columns] {
            model.mode = mode
            model.activate(model.entries[100])
            #expect(model.mode == .gallery)
            let host = NSHostingView(rootView: content(model))
            window.contentView = host
            await settle(host)
            try expectVisible(host, model: model, selected: 100)
            model.toggleGallery()
            #expect(model.mode == mode)
            host.rootView = content(model)
            await settle(host)
            try expectVisible(host, model: model, selected: 100)
            model.toggleGallery()
            #expect(model.mode == .gallery)
            #expect(model.selection.showsRAW)
            #expect(model.viewport == viewport)
        }
        let galleryHost = NSHostingView(rootView: content(model))
        window.contentView = galleryHost
        await settle(galleryHost)
        let previewCanvas = try #require(descendants(galleryHost, CanvasView.self).first)
        let previewImage = model.preview?.cgImage
        for size in FilmstripSize.allCases {
            model.filmstripSize = size
            galleryHost.rootView = content(model)
            await settle(galleryHost)
            try expectVisible(galleryHost, model: model, selected: 100)
            #expect(descendants(galleryHost, CanvasView.self).first === previewCanvas)
            #expect(model.preview?.cgImage === previewImage)
            #expect(model.viewport == viewport)
            #expect(model.selection.showsRAW)
        }
        model.mode = .icons
        for size in [90.0, 220.0] {
            model.iconSize = size
            let host = NSHostingView(rootView: content(model))
            window.contentView = host
            await settle(host)
            try expectVisible(host, model: model, selected: 100)
        }
        for mode in ViewMode.allCases {
            model.mode = mode
            for id: String? in [nil, "missing-id"] {
                model.selection.select(id)
                let host = NSHostingView(rootView: content(model))
                window.contentView = host
                await settle(host)
                #expect(model.entries.count == 200)
                let scrolls = descendants(host, NSScrollView.self)
                let scroll = try #require(mode == .columns ? scrolls.last : scrolls.first)
                #expect(scroll.documentVisibleRect.origin.y <= 0)
                #expect(scroll.documentVisibleRect.origin.x <= 0)
                if let table = descendants(host, NSTableView.self).last { #expect(table.selectedRow == -1) }
                if let collection = descendants(host, NSCollectionView.self).first { #expect(collection.selectionIndexPaths.isEmpty) }
            }
        }
    }

    private func waitForCatalog(_ model: BrowserModel, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            await Task.yield()
            if !model.loading, model.entries.count == count { return }
        } while ContinuousClock.now < deadline
        Issue.record("Synthetic catalog did not load: \(model.error ?? "no error")")
        throw CancellationError()
    }

    @Test func folderAndLibraryNavigationRejectsPendingOldSelection() async throws {
        let fixture = try await photoFixture()
        let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
            try? FileManager.default.removeItem(at: libraryRoot)
        }
        let library = PhotoLibrary(root: libraryRoot)
        _ = try await library.importPhotos(from: fixture.directory)
        let model = BrowserModel()
        model.open(fixture.directory)
        try await waitForCatalog(model, count: 200)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        for mode in [ViewMode.icons, .list] {
            model.mode = mode
            model.selection.select(model.entries[199].id)
            let host = NSHostingView(rootView: content(model))
            host.frame = NSRect(x: 0, y: 0, width: 850, height: 650)
            host.layoutSubtreeIfNeeded()
            let oldScroll = try #require(descendants(host, SelectionScrollView.self).first)
            #expect(oldScroll.revealSelection != nil)
            // Location changes before the pending reveal gets a window/layout.
            if model.isLibrary { model.open(fixture.directory) }
            else { model.libraryRoot = libraryRoot; model.openLibrary() }
            oldScroll.revealSelection?()
            #expect(oldScroll.documentVisibleRect.origin.y <= 0)
            try await waitForCatalog(model, count: 200)
            model.selection.select(model.entries[100].id)
            window.contentView = host
            host.rootView = content(model)
            await settle(host)
            try expectVisible(host, model: model, selected: 100)
            window.contentView = nil
        }
    }

    @Test func columnsRevealRightmostFolderAfterEntryAndNavigation() async throws {
        let fixture = try await photoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let folders = ["branch/one/two", "other/one/two/three/four"].map {
            fixture.directory.appendingPathComponent($0)
        }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for entry in fixture.model.entries {
                try FileManager.default.linkItem(at: entry.url, to: folder.appendingPathComponent(entry.name))
            }
        }
        let model = BrowserModel()
        model.open(folders[0])
        try await waitForCatalog(model, count: 200)
        model.selection.select(model.entries[100].id)
        model.mode = .columns
        let host = NSHostingView(rootView: content(model))
        // The mode can appear before its final split-view size is assigned.
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 450)
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)

        func expectRightmost() throws -> NSScrollView {
            let scroll = try #require(descendants(host, NSScrollView.self).first)
            let document = try #require(scroll.documentView)
            #expect(document.bounds.width > scroll.documentVisibleRect.width)
            #expect(abs(scroll.documentVisibleRect.maxX - document.bounds.maxX) < 1)
            try expectVisible(host, model: model, selected: 100)
            return scroll
        }
        let scroll = try expectRightmost()
        try capture(host, name: "columns-nested-entry")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let manualOrigin = scroll.documentVisibleRect.origin
        model.previewError = "Unrelated preview refresh"
        host.rootView = content(model)
        await settle(host)
        #expect(scroll.documentVisibleRect.origin == manualOrigin)
        // A different depth changes the horizontal content width, so this
        // catches attempts to scroll using the previous folder's layout.
        model.open(folders[1])
        try await waitForCatalog(model, count: 200)
        model.selection.select(model.entries[100].id)
        host.rootView = content(model)
        await settle(host)
        _ = try expectRightmost()
        try capture(host, name: "columns-nested")
        model.mode = .list
        host.rootView = content(model)
        await settle(host)
        model.mode = .columns
        host.rootView = content(model)
        await settle(host)
        _ = try expectRightmost()
    }

    private func expectVisible(_ host: NSView, model: BrowserModel, selected: Int) throws {
        switch model.mode {
        case .icons:
            let collection = try #require(descendants(host, NSCollectionView.self).first)
            let frame = try #require(collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: selected, section: 0))?.frame)
            #expect(collection.visibleRect.insetBy(dx: -1, dy: -1).contains(frame))
        case .list, .columns:
            let table = try #require(descendants(host, NSTableView.self).last)
            #expect(table.selectedRow == selected)
            let frame = table.rect(ofRow: selected)
            #expect(frame.minY >= table.visibleRect.minY - 1)
            #expect(frame.maxY <= table.visibleRect.maxY + 1)
        case .gallery:
            let scroll = try #require(descendants(host, NSScrollView.self).first)
            // The cell includes five points of padding on either side; the
            // strip has ten-point outer padding and ten-point spacing.
            let cellWidth = model.filmstripSize.width + 10
            let start = 10 + Double(selected) * (cellWidth + 10)
            let visible = scroll.documentVisibleRect
            #expect(start >= visible.minX - 1)
            #expect(start + cellWidth <= visible.maxX + 1)
            // LazyHStack may include its outer padding in the anchor geometry.
            if selected == 100 { #expect(abs(start + cellWidth / 2 - visible.midX) <= 10) }
        }
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_SELECTION_CAPTURE_DIR"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("selection-\(name).png"))
    }
}
