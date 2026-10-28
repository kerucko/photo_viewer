import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

private actor AcceptanceRequestCounter {
    private(set) var count = 0
    func load() async throws -> RenderedImage {
        count += 1
        try await Task.sleep(for: .seconds(30))
        throw CocoaError(.fileReadCorruptFile)
    }
}

@MainActor @Suite(.serialized) struct ComparisonAcceptanceTests {
    private func image(_ width: Int, _ height: Int, portrait: Bool) throws -> RenderedImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(portrait ? CGColor(red: 0.12, green: 0.5, blue: 0.75, alpha: 1) : CGColor(red: 0.8, green: 0.35, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return RenderedImage(cgImage: try #require(context.makeImage()))
    }
    private func settle(_ host: NSView) async {
        for _ in 0..<16 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    private func canvases(_ root: NSView) -> [CanvasView] {
        (root as? CanvasView).map { [$0] } ?? root.subviews.flatMap { canvases($0) }
    }
    private func entries() -> [CatalogEntry] {
        (0..<4).map { index in
            let url = URL(fileURLWithPath: "/synthetic/acceptance/photo-\(index)-long-distinguishable-name.jpg")
            let asset = PhotoAsset(resources: [PhotoResource(url: url), PhotoResource(url: url.deletingPathExtension().appendingPathExtension("raf"))])
            return CatalogEntry(url: url, asset: asset)
        }
    }
    private func capture(_ view: NSView, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_COMPARISON_CAPTURE_DIR"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("comparison-\(name).png"))
    }
    @Test func entryGatesKeyboardExitAndIndependentRAW() throws {
        _ = NSApplication.shared
        let model = BrowserModel(); model.entries = entries(); model.mode = .list
        let ids = model.photos.map(\.id)
        for count in [0, 1, 3, 4] {
            model.setSelectedIDs(Set(ids.prefix(count))); #expect(!model.canCompare)
        }
        model.setSelectedIDs([ids[0], ids[2]], primary: ids[2])
        model.busy = true; #expect(!model.canCompare); model.startComparison(); #expect(model.comparison == nil)
        model.busy = false; model.startComparison()
        let session = try #require(model.comparison)
        model.toggleRAW(); #expect(session.panes[1].showsRAW && !session.panes[0].showsRAW)
        model.activateComparisonPane(0); #expect(model.selectedResource?.isRAW == false)
        #expect(model.selectedAssets.count == 2 && model.trashAssets.count == 1)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        #expect(!BrowserKeyboard.handle(space, model: model, firstResponder: NSTextView()))
        #expect(model.comparison === session)
        #expect(BrowserKeyboard.handle(space, model: model, firstResponder: nil))
        #expect(model.comparison == nil && model.mode == .list && model.selection.ids == [ids[0], ids[2]])
        model.startComparison(); model.mode = .icons
        #expect(model.comparison == nil && model.mode == .icons)
    }
    @Test func sharedViewportReachesBothNativeCanvasesAndResets() async throws {
        let model = BrowserModel(); model.entries = entries(); model.mode = .gallery
        let landscape = try image(1200, 600, portrait: false), portrait = try image(600, 1200, portrait: true)
        let assets = Array(model.photos.prefix(2)).compactMap(\.asset)
        let firstID = assets[0].id
        let session = ComparisonSession(assets: assets, primary: firstID, loader: { $0.url.path == firstID ? landscape : portrait })
        model.comparison = session; model.syncComparisonSelection()
        defer { session.cancel() }
        try await wait { session.panes.allSatisfy { !$0.loading } }
        let host = NSHostingView(rootView: ComparisonView(model: model, session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        await settle(host)
        let views = canvases(host); try #require(views.count == 2)
        #expect(abs(views[0].bounds.width - views[1].bounds.width) < 1)
        #expect(views.allSatisfy { $0.viewport.scale == nil && $0.viewport.offset == .zero })
        model.actualSize(); await settle(host)
        #expect(views.allSatisfy { $0.viewport.scale == 1 })
        session.viewport.offset = CGSize(width: 37, height: -23); await settle(host)
        #expect(views.allSatisfy { $0.viewport.offset == CGSize(width: 37, height: -23) })
        model.fitPreview(); await settle(host)
        #expect(views.allSatisfy { $0.viewport == ViewportState() })
        model.activateComparisonPane(1); model.zoom(by: 1.4); await settle(host)
        let active = views.first { $0.image?.height == 1200 }
        let canvas = try #require(active)
        let fit = min(canvas.bounds.width / 600, canvas.bounds.height / 1200) * window.backingScaleFactor * 1.4
        #expect(abs((session.viewport.scale ?? 0) - fit) < 0.001)
        #expect(views.allSatisfy { $0.viewport.scale == session.viewport.scale })
    }
    @Test func unchangedResumeKeepsInflightRequests() async throws {
        let assets = Array(entries().prefix(2)).compactMap(\.asset), counter = AcceptanceRequestCounter()
        let session = ComparisonSession(assets: assets, primary: nil, loader: { _ in try await counter.load() })
        defer { session.cancel() }
        for _ in 0..<100 { if await counter.count == 2 { break }; await Task.yield() }
        try #require(await counter.count == 2)
        session.resume()
        for _ in 0..<100 { await Task.yield() }
        #expect(await counter.count == 2, "Unchanged refresh must preserve both in-flight decodes")
    }
    @Test func busyComparisonRejectsNativeCanvasPan() async throws {
        _ = NSApplication.shared
        let model = BrowserModel(); model.entries = entries(); model.mode = .gallery
        let pixels = try image(120, 80, portrait: false)
        let session = ComparisonSession(assets: Array(model.photos.prefix(2)).compactMap(\.asset), primary: nil, loader: { _ in pixels })
        model.comparison = session; model.syncComparisonSelection(); defer { session.cancel() }
        try await wait { session.panes.allSatisfy { !$0.loading } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let comparisonHost = NSHostingView(rootView: ComparisonView(model: model, session: session))
        window.contentView = comparisonHost; await settle(comparisonHost)
        let canvas = try #require(canvases(comparisonHost).first)
        let point = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: point.x + 15, y: point.y + 10), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        model.busy = true
        canvas.mouseDown(with: down); canvas.mouseDragged(with: drag)
        #expect(session.viewport.offset == .zero, "Busy operation must lock native canvas gestures")
        #expect(canvas.viewport.offset == .zero, "Busy gesture must not alter even the canvas-local drawing state")
        model.busy = false
        canvas.mouseDown(with: down)
        model.busy = true; canvas.mouseDragged(with: drag)
        #expect(session.viewport.offset == .zero && canvas.viewport.offset == .zero, "Starting an operation during a drag also locks pan")
        model.busy = false
    }
    @Test func trashCompletionKeepsOriginalTargetWhenActiveChangesDuringRefresh() throws {
        let model = BrowserModel(); model.entries = entries(); model.mode = .gallery
        let ids = model.photos.map(\.id)
        model.setSelectedIDs([ids[0], ids[1]], primary: ids[0]); model.startComparison()
        let session = try #require(model.comparison)
        // Snapshot before asynchronous trash; removal finishes before catalog refresh resumes.
        let originalTarget = session.active
        let snapshot = ComparisonTrashSnapshot(session: session, photoIDs: ids)
        model.entries.removeAll { $0.id == ids[0] }
        model.activateComparisonPane(1)
        model.completeComparisonTrash(snapshot: snapshot, succeeded: true)
        #expect(session.panes[originalTarget].asset.id == ids[2], "Replacement belongs in the slot captured before trash")
        #expect(session.panes[1].asset.id == ids[1], "The surviving pane must remain unchanged")
        session.cancel()
    }
    @Test func syntheticStateRendersAndBoundedNativeWindowCapture() async throws {
        guard ProcessInfo.processInfo.environment["PHOTOVIEWER_COMPARISON_CAPTURE_DIR"] != nil else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let landscape = try image(1200, 600, portrait: false), portrait = try image(600, 1200, portrait: true)
        for (name, image) in [("landscape.jpg", landscape), ("portrait.jpg", portrait)] {
            let data = try #require(NSBitmapImageRep(cgImage: image.cgImage).representation(using: .jpeg, properties: [:]))
            try data.write(to: root.appendingPathComponent(name))
        }
        let model = BrowserModel(); model.open(root)
        try await wait { !model.loading && model.photos.count == 2 }
        model.mode = .gallery
        let assets = model.photos.compactMap(\.asset)
        for state in ["mixed-active-left", "zoom-active-right", "loading", "error", "inspector"] {
            let session = ComparisonSession(assets: assets, primary: assets[0].id, loader: { resource in
                if state == "loading", resource.url.lastPathComponent == "portrait.jpg" {
                    try await Task.sleep(for: .seconds(30))
                }
                if state == "error", resource.url.lastPathComponent == "portrait.jpg" { throw CocoaError(.fileReadCorruptFile) }
                return resource.url.lastPathComponent == "portrait.jpg" ? portrait : landscape
            })
            model.comparison = session; model.syncComparisonSelection()
            if state == "loading" { try await wait { session.panes[0].image != nil } }
            else { try await wait { session.panes.allSatisfy { !$0.loading } } }
            if state == "zoom-active-right" { model.activateComparisonPane(1); model.actualSize(); session.viewport.offset = CGSize(width: 35, height: -25) }
            model.showMetadata = state == "inspector"
            for size in [NSSize(width: 850, height: 650), NSSize(width: 1280, height: 800)] {
                let controller = NSHostingController(rootView: BrowserView(model: model).frame(width: size.width, height: size.height))
                let window = NSWindow(contentViewController: controller)
                window.styleMask = [.titled, .closable, .resizable]
                defer { window.contentViewController = nil; window.orderOut(nil) }
                window.setContentSize(size); window.makeKeyAndOrderFront(nil); await settle(controller.view)
                let suffix = "\(Int(size.width))x\(Int(size.height))"
                try capture(controller.view, "\(state)-\(suffix)")
                if ["mixed-active-left", "inspector"].contains(state), let frame = window.contentView?.superview {
                    await settle(frame)
                    try capture(frame, "native-frame-\(state)-\(suffix)")
                }
            }
            session.cancel()
        }
        model.showMetadata = false
    }
}
