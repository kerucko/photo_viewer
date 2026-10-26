import AppKit
import SwiftUI
import Testing
import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct ColumnsPreviewTests {
    private func fixture() throws -> (model: BrowserModel, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = BrowserModel()
        model.mode = .columns
        model.entries = try (0..<4).map { index in
            let width = 48 + index * 16
            let context = try #require(CGContext(data: nil, width: width, height: 32, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / 3, green: 0.4, blue: 1 - CGFloat(index) / 3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: 32))
            let image = try #require(context.makeImage())
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]))
            let url = directory.appendingPathComponent("Photo-\(index).jpg")
            try data.write(to: url)
            return CatalogEntry(url: url, asset: PhotoAsset(resources: [PhotoResource(url: url)]))
        }
        return (model, directory)
    }
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    private func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func waitForPreview(_ model: BrowserModel, index: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.previewLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.selection.id == model.entries[index].id)
        #expect(!model.previewLoading)
        #expect(model.previewError == nil)
        let image = try #require(model.preview?.cgImage)
        #expect(image.width == 48 + index * 16)
        #expect(image.height == 32)
    }
    private func expectCanvas(_ host: NSView, model: BrowserModel) throws {
        let canvas = try #require(descendants(host, CanvasView.self).first)
        #expect(canvas.image === model.preview?.cgImage)
    }
    private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_COLUMNS_CAPTURE_DIR"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("columns-preview-\(name).png"))
    }

    // Exercise the native List selection delegate and rendered canvas. Delivery
    // of physical mouse events to SwiftUI's gesture recognizers is a manual check.
    @Test func listSelectionReplacesPreviousPreviewAndCanvas() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        model.select(model.entries[0].id)
        try await waitForPreview(model, index: 0)
        let host = NSHostingView(rootView: ColumnBrowser(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        try expectCanvas(host, model: model)
        try capture(host, name: "initial")
        let table = try #require(descendants(host, NSTableView.self).last)
        for index in [1, 3, 2, 0] {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            await settle(host)
            try await waitForPreview(model, index: index)
            await settle(host)
            try expectCanvas(host, model: model)
            if index == 3 { try capture(host, name: "changed") }
        }
    }

    @Test func rapidSelectionAndGalleryKeepNewestPrimaryImageAndGroup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        let ids = model.entries.map(\.id)
        for index in [0, 1, 2, 0, 3] { model.setSelectedIDs([ids[index]]) }
        try await waitForPreview(model, index: 3)
        model.setSelectedIDs([ids[1], ids[3]], primary: ids[3])
        let previous = model.preview?.cgImage
        model.activate(model.entries[3])
        #expect(model.mode == .gallery)
        #expect(model.selection.ids == [ids[1], ids[3]])
        #expect(model.preview?.cgImage === previous)
        model.toggleGallery()
        #expect(model.mode == .columns)
        model.activate(model.entries[1])
        try await waitForPreview(model, index: 1)
        #expect(model.selection.ids == [ids[1], ids[3]])
        model.toggleGallery()
        let host = NSHostingView(rootView: ColumnBrowser(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        try expectCanvas(host, model: model)
        try capture(host, name: "group-after-gallery")
    }
}
