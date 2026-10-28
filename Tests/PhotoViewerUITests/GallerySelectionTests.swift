import AppKit
import SwiftUI
import Testing
import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct GallerySelectionTests {
    private func settle(_ view: NSView) async {
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func targets(_ view: NSView) -> [GalleryThumbnailClickView] {
        (view as? GalleryThumbnailClickView).map { [$0] } ?? view.subviews.flatMap { targets($0) }
    }
    private func click(_ target: GalleryThumbnailClickView, window: NSWindow, command: Bool = false, count: Int = 1) throws {
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: command ? .command : [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        let content = try #require(window.contentView)
        let hitPoint = content.superview?.convert(point, from: nil) ?? point
        let hit = content.hitTest(hitPoint)
        #expect(hit === target)
        hit?.mouseDown(with: event)
    }
    @Test func nativeCommandClicksBuildToggleAndComparePair() async throws {
        let model = BrowserModel(); model.mode = .gallery
        model.entries = (0..<4).map { index in
            let url = URL(fileURLWithPath: "/synthetic/gallery-\(index).jpg")
            return CatalogEntry(url: url, asset: PhotoAsset(resources: [PhotoResource(url: url)]))
        }
        let ids = model.entries.map(\.id)
        let host = NSHostingView(rootView: GalleryView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil; model.comparison?.cancel() }
        await settle(host)
        func target(_ index: Int) throws -> GalleryThumbnailClickView { try #require(targets(host).first { $0.entryID == ids[index] }) }
        try click(target(0), window: window)
        #expect(model.selection.ids == [ids[0]])
        try click(target(1), window: window, command: true)
        #expect(model.selection.ids == [ids[0], ids[1]] && model.selection.id == ids[1] && model.canCompare)
        try click(target(1), window: window, command: true)
        #expect(model.selection.ids == [ids[0]] && !model.canCompare)
        try click(target(2), window: window, command: true)
        #expect(model.selection.ids == [ids[0], ids[2]])
        // A double click on a member preserves the group captured before its first down.
        try click(target(0), window: window)
        try click(target(0), window: window, count: 2)
        #expect(model.selection.ids == [ids[0], ids[2]] && model.selection.id == ids[0])
        model.startComparison(); let session = try #require(model.comparison)
        await settle(host)
        try click(target(1), window: window, command: true)
        #expect(model.selection.ids == [ids[1], ids[2]] && session.panes.count == 2)
        try click(target(2), window: window, command: true)
        #expect(session.activePane.asset.id == ids[2] && model.selection.ids.count == 2)
        model.exitComparison(); await settle(host)
        try click(target(3), window: window)
        #expect(model.selection.ids == [ids[3]])
        model.busy = true
        try click(target(0), window: window, command: true)
        #expect(model.selection.ids == [ids[3]])
        model.busy = false
    }
    @Test func commandClickFolderRemainsSingleSelection() throws {
        let model = BrowserModel(); model.mode = .gallery
        let photo = URL(fileURLWithPath: "/synthetic/a.jpg"), folder = URL(fileURLWithPath: "/synthetic/subfolder")
        model.entries = [CatalogEntry(url: photo, asset: PhotoAsset(resources: [PhotoResource(url: photo)])), CatalogEntry(url: folder)]
        model.select(photo.path)
        let view = GalleryThumbnailClickView(); view.model = model; view.entryID = folder.path
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        #expect(model.selection.ids == [folder.path] && !model.canCompare)
    }
}
