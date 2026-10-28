import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct GallerySpacingAcceptanceTests {
    private func settle(_ view: NSView) async {
        for _ in 0..<20 {
            view.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
    private func targets(_ view: NSView) -> [GalleryThumbnailClickView] {
        (view as? GalleryThumbnailClickView).map { [$0] } ?? view.subviews.flatMap { targets($0) }
    }
    private func capture(_ view: NSView, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_GALLERY_CAPTURE_DIR"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("gallery-\(name).png"))
    }
    private func component(_ model: BrowserModel, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_GALLERY_CAPTURE_DIR"] else { return }
        let renderer = ImageRenderer(content: GalleryActionsToolbarView(model: model).padding(12))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("component-\(name).png"))
    }
    @Test func nativeCommandSelectionEnablesComparisonAndCapturesToolbar() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, name) in ["a-pair.jpg", "b-photo.jpg", "c-photo.jpg"].enumerated() {
            let context = try #require(CGContext(data: nil, width: 300, height: 180, bitsPerComponent: 8,
                bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index + 1) / 4, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 180))
            let image = try #require(context.makeImage())
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]))
            try data.write(to: root.appendingPathComponent(name))
        }
        // Deliberately synthetic invalid RAW: label/action capture is not a decoder check.
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("a-pair.raf"))
        let model = BrowserModel(); let metadata = model.showMetadata
        model.showMetadata = false; defer { model.showMetadata = metadata; model.comparison?.cancel() }
        model.open(root); try await wait { !model.loading && model.photos.count == 3 }; model.mode = .gallery
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 850, height: 650)] {
            model.exitComparison(); model.select(model.photos[1].id)
            let controller = NSHostingController(rootView: BrowserView(model: model).frame(width: size.width, height: size.height))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable]; window.setContentSize(size)
            window.makeKeyAndOrderFront(nil); defer { window.orderOut(nil); window.contentViewController = nil }
            await settle(controller.view)
            let frame = try #require(window.contentView?.superview)
            let suffix = "\(Int(size.width))x\(Int(size.height))"
            try capture(frame, "jpg-disabled-\(suffix)")
            try component(model, "jpg-disabled-\(suffix)")
            func click(_ index: Int, flags: NSEvent.ModifierFlags = []) throws {
                let target = try #require(targets(controller.view).first { $0.entryID == model.photos[index].id })
                let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
                let hit = frame.hitTest(frame.convert(point, from: nil))
                #expect(hit === target)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    if type == .leftMouseDown { hit?.mouseDown(with: event) }
                    else { hit?.mouseUp(with: event) }
                }
            }
            try click(2, flags: .command); await settle(controller.view)
            #expect(model.selection.ids == Set(model.photos[1...2].map(\.id)) && model.canCompare)
            try capture(frame, "jpg-enabled-\(suffix)")
            try component(model, "jpg-enabled-\(suffix)")
            // In-process SwiftUI toolbar AX controls are unavailable in swiftpm-testing-helper.
            // This invokes the model command; it does not claim a physical toolbar click.
            model.startComparison()
            try #require(model.comparison != nil); await settle(controller.view)
            try capture(frame, "jpg-exit-\(suffix)")
            try component(model, "jpg-exit-\(suffix)")
            model.exitComparison(); try #require(model.comparison == nil); await settle(controller.view)
            try click(0); await settle(controller.view)
            #expect(model.selection.ids == [model.photos[0].id])
            try capture(frame, "pair-jpg-disabled-\(suffix)")
            try component(model, "pair-jpg-disabled-\(suffix)")
            try click(1, flags: .command); await settle(controller.view)
            try capture(frame, "pair-enabled-\(suffix)")
            // The primary is the second photo; activate the pair without changing the two-photo group.
            model.setSelectedIDs([model.photos[0].id, model.photos[1].id], primary: model.photos[0].id)
            await settle(controller.view)
            try component(model, "pair-jpg-enabled-\(suffix)")
            model.toggleRAW(); await settle(controller.view)
            #expect(model.showsRAW)
            try capture(frame, "pair-raw-enabled-\(suffix)")
            try component(model, "pair-raw-enabled-\(suffix)")
        }
    }
}
