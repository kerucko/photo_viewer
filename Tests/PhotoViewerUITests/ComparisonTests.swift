import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

private actor ComparisonGate {
    var requests: [PhotoResource: [CheckedContinuation<RenderedImage, any Error>]] = [:]
    func load(_ resource: PhotoResource) async throws -> RenderedImage {
        try await withCheckedThrowingContinuation { requests[resource, default: []].append($0) }
    }
    func fail(_ resource: PhotoResource) {
        let pending = requests.removeValue(forKey: resource) ?? []
        pending.forEach { $0.resume(throwing: CocoaError(.fileReadCorruptFile)) }
    }
    func count(_ resource: PhotoResource) -> Int { requests[resource]?.count ?? 0 }
    func resolve(_ resource: PhotoResource, image: RenderedImage) {
        let pending = requests.removeValue(forKey: resource) ?? []
        pending.forEach { $0.resume(returning: image) }
    }
}

@MainActor @Suite(.serialized) struct ComparisonTests {
    private func assets(_ count: Int = 5) -> [PhotoAsset] {
        (0..<count).map { index in
            let url = URL(fileURLWithPath: "/synthetic/comparison-\(index).jpg")
            return PhotoAsset(resources: [PhotoResource(url: url), PhotoResource(url: url.deletingPathExtension().appendingPathExtension("raf"))])
        }
    }
    private func model(_ count: Int = 5) -> BrowserModel {
        let model = BrowserModel(); model.mode = .icons
        model.entries = assets(count).map { CatalogEntry(url: $0.preferred.url, asset: $0) }
        return model
    }
    private func rendered(_ width: Int, _ height: Int) throws -> RenderedImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return RenderedImage(cgImage: try #require(context.makeImage()))
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await condition())
    }
    @Test func entryOrderActiveReplacementBoundariesAndExit() throws {
        let model = model(), ids = model.photos.map(\.id)
        model.setSelectedIDs([ids[1], ids[3]], primary: ids[3])
        #expect(model.canCompare)
        model.loading = true; #expect(!model.canCompare); model.loading = false
        model.startComparison()
        let session = try #require(model.comparison)
        #expect(session.panes.map { $0.asset.id } == [ids[1], ids[3]])
        #expect(session.active == 1 && model.mode == .gallery)
        #expect(model.trashAssets.map(\.id) == [ids[3]])
        #expect(model.selectedAssets.count == 2)
        session.viewport = ViewportState(scale: 2, offset: CGSize(width: 30, height: -40))
        model.selectGesture(ids[1], command: true, shift: true)
        #expect(session.active == 0 && model.selection.ids == [ids[1], ids[3]])
        model.step(1); #expect(session.activePane.asset.id == ids[2])
        model.step(1); #expect(session.activePane.asset.id == ids[4])
        model.step(1); #expect(session.activePane.asset.id == ids[4])
        #expect(session.viewport.scale == 2 && session.viewport.offset.width == 30)
        model.toggleRAW(); #expect(model.selectedResource?.isRAW == true)
        model.activateComparisonPane(1); model.activateComparisonPane(0)
        #expect(model.showsRAW)
        model.busy = true; model.step(-1); model.exitComparison(); model.activateComparisonPane(1)
        #expect(model.comparison === session && session.active == 0 && session.activePane.asset.id == ids[4])
        model.busy = false; model.exitComparison()
        #expect(model.comparison == nil && model.mode == .gallery && model.selection.id == ids[4])
        #expect(model.selection.ids == [ids[3], ids[4]] && model.selection.showsRAW)
    }
    @Test func sortRefreshPartialPairAndExternalRemoval() throws {
        let model = model(), ids = model.photos.map(\.id)
        model.setSelectedIDs([ids[1], ids[3]], primary: ids[1]); model.startComparison()
        let session = try #require(model.comparison)
        model.setSort(.name)
        #expect(session.panes.map { $0.asset.id } == [ids[1], ids[3]])
        let raw = try #require(session.panes[0].asset.raw)
        model.entries = model.entries.map { $0.id == ids[1] ? CatalogEntry(url: raw.url, asset: PhotoAsset(resources: [raw])) : $0 }
        model.reconcileSelection()
        #expect(model.comparison === session && session.panes[0].asset.id == raw.url.path)
        #expect(model.selection.id == raw.url.path && model.selectedResource == raw)
        model.entries.removeAll { $0.id == raw.url.path }; model.reconcileSelection()
        #expect(model.comparison == nil && model.selection.id == ids[3])
    }
    @Test func trashReplacementFallbackPartialAndNone() throws {
        let model = model(), ids = model.photos.map(\.id)
        model.setSelectedIDs([ids[1], ids[2]], primary: ids[1]); model.startComparison()
        let session = try #require(model.comparison)
        model.completeComparisonTrash(snapshot: ComparisonTrashSnapshot(session: session, photoIDs: ids), succeeded: false)
        #expect(session.activePane.asset.id == ids[1])
        model.completeComparisonTrash(snapshot: ComparisonTrashSnapshot(session: session, photoIDs: ids), succeeded: true)
        #expect(session.activePane.asset.id == ids[3])
        model.replaceComparison(with: ids[4])
        model.completeComparisonTrash(snapshot: ComparisonTrashSnapshot(session: session, photoIDs: ids), succeeded: true)
        #expect(session.activePane.asset.id == ids[3])
        model.replaceComparison(with: ids[0])
        model.entries.removeAll { $0.id == ids[1] }
        model.completeComparisonTrash(snapshot: ComparisonTrashSnapshot(session: session, photoIDs: ids), succeeded: true)
        #expect(session.activePane.asset.id == ids[3]) // Missing next and other visible photo are skipped.
        let two = self.model(2), twoIDs = two.photos.map(\.id)
        two.setSelectedIDs(Set(twoIDs), primary: twoIDs[0]); two.startComparison()
        two.completeComparisonTrash(snapshot: ComparisonTrashSnapshot(session: try #require(two.comparison), photoIDs: twoIDs), succeeded: true)
        #expect(two.comparison == nil && two.mode == .gallery && two.selection.ids == [twoIDs[1]])
    }
    @Test func trashSnapshotPreservesSlotAcrossActiveChangesAndRejectsStaleAsset() throws {
        let model = model(), ids = model.photos.map(\.id)
        model.setSelectedIDs([ids[0], ids[1]], primary: ids[0]); model.startComparison()
        let session = try #require(model.comparison)
        let snapshot = ComparisonTrashSnapshot(session: session, photoIDs: ids)
        model.activateComparisonPane(1)
        model.entries.removeAll { $0.id == ids[0] }
        model.busy = true
        model.completeComparisonTrash(snapshot: snapshot, succeeded: true)
        #expect(session.panes[0].asset.id == ids[2] && session.panes[1].asset.id == ids[1])
        #expect(session.active == 1 && model.busy)
        model.completeComparisonTrash(snapshot: snapshot, succeeded: true)
        #expect(session.panes[0].asset.id == ids[2])
        model.busy = false; session.cancel()
    }
    @Test func independentRequestsDiscardLateReplacementAndCancellation() async throws {
        let assets = assets(), gate = ComparisonGate()
        let session = ComparisonSession(assets: Array(assets.prefix(2)), primary: assets[0].id, loader: { try await gate.load($0) })
        try await wait {
            let a = await gate.count(assets[0].preferred), b = await gate.count(assets[1].preferred)
            return a == 1 && b == 1
        }
        session.replace(0, with: assets[2])
        try await wait { await gate.count(assets[2].preferred) == 1 }
        let first = try rendered(100, 80), newest = try rendered(300, 90)
        await gate.resolve(assets[0].preferred, image: first)
        await gate.resolve(assets[1].preferred, image: first)
        await gate.resolve(assets[2].preferred, image: newest)
        try await wait { !session.panes[0].loading && !session.panes[1].loading }
        #expect(session.panes[0].image?.cgImage.width == 300 && session.panes[1].image?.cgImage.width == 100)
        session.toggleRAW()
        let raw = try #require(assets[2].raw)
        try await wait { await gate.count(raw) == 1 }
        session.cancel(); await gate.resolve(raw, image: first)
        for _ in 0..<10 { await Task.yield() }
        #expect(session.panes[0].image == nil && !session.panes[0].loading)
    }
    @Test func sharedPhysicalScaleUsesActiveRetinaGeometryAndPreservesOffset() async throws {
        let assets = assets(), gate = ComparisonGate()
        let session = ComparisonSession(assets: Array(assets.prefix(2)), primary: assets[0].id, loader: { try await gate.load($0) })
        try await wait {
            let a = await gate.count(assets[0].preferred), b = await gate.count(assets[1].preferred)
            return a == 1 && b == 1
        }
        await gate.resolve(assets[0].preferred, image: try rendered(1000, 500))
        await gate.resolve(assets[1].preferred, image: try rendered(500, 1000))
        try await wait { !session.panes[0].loading && !session.panes[1].loading }
        session.setGeometry(CGSize(width: 400, height: 300), backingScale: 2, for: 0)
        session.setGeometry(CGSize(width: 400, height: 300), backingScale: 2, for: 1)
        session.zoom(by: 1.4); #expect(abs((session.viewport.scale ?? 0) - 1.12) < 0.0001)
        session.viewport = ViewportState(); session.active = 1
        session.zoom(by: 1.4); #expect(abs((session.viewport.scale ?? 0) - 0.84) < 0.0001)
        session.viewport.offset = CGSize(width: 50, height: -20)
        session.replace(1, with: assets[3])
        #expect(session.viewport.offset == CGSize(width: 50, height: -20) && session.viewport.scale != nil)
        session.cancel()
        try await wait { await gate.count(assets[3].preferred) == 1 }
        await gate.resolve(assets[3].preferred, image: try rendered(20, 20))
    }
    @Test func canvasHitTestingDragAndIndependentFailure() async throws {
        let model = model(2), assets = model.photos.compactMap(\.asset), gate = ComparisonGate()
        let session = ComparisonSession(assets: assets, primary: assets[0].id, loader: { try await gate.load($0) })
        model.mode = .gallery; model.comparison = session; model.syncComparisonSelection()
        try await wait {
            let a = await gate.count(assets[0].preferred), b = await gate.count(assets[1].preferred)
            return a == 1 && b == 1
        }
        await gate.fail(assets[0].preferred)
        await gate.resolve(assets[1].preferred, image: try rendered(100, 200))
        try await wait { !session.panes[0].loading && !session.panes[1].loading }
        #expect(session.panes[0].error != nil && session.panes[1].image != nil)
        let host = NSHostingView(rootView: ComparisonView(model: model, session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; session.cancel() }
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        func canvases(_ root: NSView) -> [CanvasView] {
            (root as? CanvasView).map { [$0] } ?? root.subviews.flatMap { canvases($0) }
        }
        let canvas = try #require(canvases(host).first)
        let center = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let hostPoint = host.convert(center, from: canvas)
        #expect(host.hitTest(hostPoint) === canvas)
        let windowPoint = canvas.convert(center, to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down)
        #expect(session.active == 1 && model.selection.id == assets[1].id)
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged,
            location: NSPoint(x: windowPoint.x + 20, y: windowPoint.y + 15), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDragged(with: drag)
        #expect(session.viewport.offset == CGSize(width: -20, height: -15))
        let beforeBusy = canvas.viewport
        model.busy = true
        canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: drag)
        #expect(canvas.viewport == beforeBusy && session.viewport == beforeBusy)
        model.busy = false

        #expect(BrowserKeyboard.handle(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)), model: model, firstResponder: canvas))
        #expect(session.active == 0)
    }

}
