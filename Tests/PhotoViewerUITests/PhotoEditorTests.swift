import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct PhotoEditorTests {
    private func preferences() -> [(String, Any?)] { ["mode", "photoGrid", "showMetadata"].map { ($0, UserDefaults.standard.object(forKey: $0)) } }
    private func restore(_ values: [(String, Any?)]) { values.forEach { UserDefaults.standard.set($0.1, forKey: $0.0) } }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition(), sourceLocation: sourceLocation)
    }
    private func image(width: Int = 600, height: Int = 400) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (rect, color) in [(CGRect(x: 0, y: 0, width: width / 2, height: height / 2), NSColor.systemOrange), (CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2), NSColor.systemIndigo)] {
            context.setFillColor(color.cgColor); context.fill(rect)
        }
        return try #require(context.makeImage())
    }
    private func fixture() throws -> (URL, PhotoEditStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<3 {
            let image = try image(width: index == 1 ? 400 : 600, height: index == 1 ? 600 : 400)
            let bytes = try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]))
            try bytes.write(to: root.appendingPathComponent("photo\(index).jpg"))
        }
        return (root, PhotoEditStore(folder: root, storageURL: root.appendingPathComponent("recipes/edits.json")))
    }
    private func model(root: URL, store: PhotoEditStore) async throws -> BrowserModel {
        let model = BrowserModel(editStoreFactory: { _ in store }); model.mode = .icons; model.open(root)
        try await wait { !model.loading && model.photos.count == 3 }
        return model
    }
    @Test func saveCancelAndComparisonEntryPreserveGroupAndGateActions() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root, store: store)
        let ids = model.photos.map(\.id), originalBytes = try Data(contentsOf: model.photos[0].url)
        model.setSelectedIDs([ids[0], ids[1]], primary: ids[1]); model.startComparison()
        model.startEditing()
        let session = try #require(model.editor)
        try await wait { session.ready && !session.loading }
        #expect(model.comparison == nil && model.mode == .gallery && session.asset.id == ids[1])
        #expect(model.selection.ids == [ids[0], ids[1]])
        session.setAspect(.original)
        #expect(session.draft.portrait && session.draft.crop == .full)
        session.setAspect(.square); session.draft.angleDegrees = 12.3
        let draft = session.draft
        model.step(1); model.select(ids[2]); model.setSelectedIDs([ids[2]]); model.toggleGallery(); model.mode = .list
        model.startComparison(); model.open(root.deletingLastPathComponent()); model.zoom(by: 2); model.createZIP()
        #expect(model.editor === session && model.mode == .gallery && model.selection.id == ids[1])
        #expect(!model.canTrash && !model.canCompare && !model.canExportZIP && !model.canZoom)
        model.reload(); #expect(session.draft == draft)
        #expect(await model.finishEditing(save: true))
        try await wait { (model.preview != nil || model.previewError != nil) && !model.loading }
        #expect(model.preview != nil, "Saved preview failed: \(model.previewError ?? "none")")
        #expect(model.editor == nil && model.selection.ids == [ids[0], ids[1]])
        #expect(try await store.load(for: session.asset).edit == draft)
        #expect(try Data(contentsOf: model.photos[0].url) == originalBytes)
        model.startEditing(); let second = try #require(model.editor)
        try await wait { second.ready && !second.loading }
        second.reset(); #expect(second.dirty)
        #expect(await model.finishEditing(save: false))
        #expect(try await store.load(for: session.asset).edit == draft)
    }
    @Test func saveFailureLeavesDraftAndCanRetryWithoutChangingOriginal() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocked")
        let store = PhotoEditStore(folder: root, storageURL: blocker.appendingPathComponent("edits.json"))
        let model = try await model(root: root, store: store)
        model.startEditing(); let session = try #require(model.editor)
        try await wait { session.ready && !session.loading }
        session.draft.angleDegrees = 4.5
        // Introduce an I/O failure after obtaining a valid resource token.
        try Data([1]).write(to: blocker)
        #expect(!(await model.finishEditing(save: true)))
        #expect(model.editor === session && session.draft.angleDegrees == 4.5 && session.error != nil)
        try FileManager.default.removeItem(at: blocker)
        #expect(await model.finishEditing(save: true))
    }
    @Test func nativeEightHandlesMoveAndAspectConstraint() throws {
        let preferences = preferences(); defer { restore(preferences) }
        let canvas = CropCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        canvas.image = try image(); canvas.edit.crop = PhotoCrop(x: 0.15, y: 0.2, width: 0.6, height: 0.6)
        for handle in CropCanvasView.Handle.allCases { #expect(canvas.handle(at: canvas.point(for: handle)) == handle) }
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas; defer { window.contentView = nil }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let p = canvas.point(for: .move), old = canvas.edit.crop
        canvas.mouseDown(with: try event(.leftMouseDown, p)); canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: p.x + 30, y: p.y + 20)))
        canvas.mouseUp(with: try event(.leftMouseUp, p))
        #expect(abs(canvas.edit.crop.x - old.x - 0.05) < 0.0001)
        #expect(abs(canvas.edit.crop.y - old.y - 0.05) < 0.0001)
        canvas.edit.setAspect(.square, portrait: false, sourceSize: CGSize(width: 600, height: 400))
        let handle = canvas.point(for: .bottomRight)
        canvas.mouseDown(with: try event(.leftMouseDown, handle)); canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: handle.x - 90, y: handle.y - 10)))
        let crop = canvas.edit.crop
        #expect(abs(crop.width * 600 - crop.height * 400) < 0.001)
        #expect(crop.isValid)
    }
    @Test func gridPreferenceIsIndependentOfDraftAndCleanCloseDoesNotAsk() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let original = UserDefaults.standard.object(forKey: "photoGrid")
        defer { UserDefaults.standard.set(original, forKey: "photoGrid") }
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root, store: store)
        model.startEditing(); let session = try #require(model.editor)
        try await wait { session.ready && !session.loading }
        model.grid = .sixths; #expect(!session.dirty)
        var closed: Bool?
        model.requestClose { closed = $0 }
        try await wait { closed != nil }
        #expect(closed == true && model.editor == nil)
        #expect(BrowserModel().grid == .sixths)
    }
    @Test func dirtyCloseChoicesAndFailedSaveKeepCorrectSession() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocked")
        let store = PhotoEditStore(folder: root, storageURL: blocker.appendingPathComponent("edits.json"))
        let model = try await model(root: root, store: store)
        model.startEditing(); let session = try #require(model.editor)
        try await wait { session.ready && !session.loading }; session.draft.angleDegrees = 8
        var closed: Bool?
        model.requestClose(choice: .cancel) { closed = $0 }
        #expect(closed == false && model.editor === session && session.dirty)
        try Data([1]).write(to: blocker); closed = nil
        model.requestClose(choice: .save) { closed = $0 }; try await wait { closed != nil }
        #expect(closed == false && model.editor === session && session.error != nil)
        try FileManager.default.removeItem(at: blocker); closed = nil
        model.requestClose(choice: .save) { closed = $0 }; try await wait { closed != nil }
        #expect(closed == true && model.editor == nil)
        model.startEditing(); let second = try #require(model.editor)
        try await wait { second.ready && !second.loading }; second.reset(); closed = nil
        model.requestClose(choice: .discard) { closed = $0 }; try await wait { closed != nil }
        #expect(closed == true && model.editor == nil)
        #expect(try await store.load(for: second.asset).edit.angleDegrees == 8)
    }
    @Test func lateRawAndCancelledRequestsCannotReplaceLatestImageOrDraft() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let jpg = root.appendingPathComponent("photo0.jpg"), raw = root.appendingPathComponent("photo0.raf")
        try Data([1, 2, 3]).write(to: raw)
        let asset = PhotoAsset(resources: [PhotoResource(url: jpg), PhotoResource(url: raw)])
        let store = PhotoEditStore(folder: root, storageURL: root.appendingPathComponent("recipes/edits.json"))
        let gate = EditImageGate()
        let session = EditorSession(asset: asset, showsRAW: false, initial: .identity, store: store, loader: { try await gate.load($0) })
        session.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.count(jpg) < 1, ContinuousClock.now < deadline { await Task.yield() }
        #expect(session.ready)
        session.draft.angleDegrees = 9.4
        session.toggleRAW()
        while await gate.count(raw) < 1, ContinuousClock.now < deadline { await Task.yield() }
        session.toggleRAW()
        while await gate.count(jpg) < 2, ContinuousClock.now < deadline { await Task.yield() }
        let newest = RenderedImage(cgImage: try image(width: 300, height: 200))
        await gate.resolve(jpg, at: 1, image: newest)
        try await wait { !session.loading }
        await gate.resolve(raw, at: 0, image: RenderedImage(cgImage: try image(width: 80, height: 120)))
        await gate.resolve(jpg, at: 0, image: RenderedImage(cgImage: try image(width: 100, height: 80)))
        for _ in 0..<20 { await Task.yield() }
        #expect(session.image?.cgImage.width == 300 && session.draft.angleDegrees == 9.4)
        session.toggleRAW()
        while await gate.count(raw) < 2, ContinuousClock.now < deadline { await Task.yield() }
        session.cancel(); await gate.resolve(raw, at: 1, image: newest)
        for _ in 0..<20 { await Task.yield() }
        #expect(session.image == nil && session.draft.angleDegrees == 9.4)
    }
    @Test func inFlightCatalogRefreshCannotMutateEditorUntilExit() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = EditCatalogGate()
        let model = BrowserModel(catalog: catalog, editStoreFactory: { _ in store }); model.mode = .gallery; model.open(root)
        try await wait { model.photos.count == 3 && !model.loading }
        catalog.block(); model.reload(); #expect(model.loading); try await wait { catalog.started && model.loading }
        let selected = model.selection.id, entries = model.entries
        model.startEditing(); let session = try #require(model.editor)
        try await wait { session.ready && !session.loading }; session.draft.angleDegrees = 13
        catalog.release(hide: true); try await wait { catalog.finished }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.editor === session && model.entries == entries && model.selection.id == selected)
        #expect(session.draft.angleDegrees == 13 && !model.loading)
        #expect(await model.finishEditing(save: false))
        try await wait { model.entries.isEmpty && !model.loading }
    }

    @Test func selectingLoadedAncestorUsesThatFoldersRecipeStore() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(contentsOf: root.appendingPathComponent("photo0.jpg")).write(to: child.appendingPathComponent("child.jpg"))
        let factory: (BrowserModel.Location) -> PhotoEditStore = { location in
            PhotoEditStore(folder: location.url, storageURL: root.appendingPathComponent("stores/" + location.url.lastPathComponent + ".json"))
        }
        let model = BrowserModel(editStoreFactory: factory); model.mode = .columns; model.open(root)
        try await wait { !model.loading && model.columns.allSatisfy { !$0.loading } }
        let parentAsset = try #require(model.photos.first?.asset)
        model.clickColumn(root.path, entryID: child.path)
        try await wait { model.folder?.path == child.path && !model.loading }
        let childAsset = try #require(model.photos.first?.asset)
        model.clickColumn(child.path, entryID: childAsset.id)
        // This reuses the loaded parent column without a new directory scan.
        model.clickColumn(root.path, entryID: parentAsset.id)
        #expect(model.folder?.path == root.path)
        model.startEditing(); let second = try #require(model.editor)
        try await wait { second.ready && !second.loading }; second.draft.angleDegrees = 6.7
        #expect(await model.finishEditing(save: true))
        #expect(try await factory(.folder(root)).load(for: parentAsset).edit.angleDegrees == 6.7)
    }
    @Test func canvasAndSavedRendererShareTopLeftGeometry() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let source = try image(width: 600, height: 400), sourceImage = RenderedImage(cgImage: try image(width: 600, height: 400))
        for turns in 0..<4 {
            let edit = PhotoEdit(quarterTurns: turns, angleDegrees: turns == 0 ? 0 : 17.2)
            let rendered = try await Task.detached { RenderedImage(cgImage: try PhotoEditRenderer.render(sourceImage.cgImage, edit: edit, maxPixel: nil)) }.value.cgImage
            let canvas = CropCanvasView(frame: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
            canvas.image = source; canvas.edit = edit
            let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            let expected = NSBitmapImageRep(cgImage: rendered)
            // Sample well inside each quadrant, away from the crop outline and color borders.
            for point in [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.8, y: 0.8)] {
                let actual = try #require(bitmap.colorAt(x: Int(point.x * Double(bitmap.pixelsWide)), y: Int(point.y * Double(bitmap.pixelsHigh)))?.usingColorSpace(.deviceRGB))
                let target = try #require(expected.colorAt(x: Int(point.x * Double(expected.pixelsWide)), y: Int(point.y * Double(expected.pixelsHigh)))?.usingColorSpace(.deviceRGB))
                #expect(abs(actual.redComponent - target.redComponent) < 0.08)
                #expect(abs(actual.greenComponent - target.greenComponent) < 0.08)
                #expect(abs(actual.blueComponent - target.blueComponent) < 0.08)
            }
        }
    }
    @Test func identityComparisonAndThumbnailRefreshAfterSameMetadataReplacement() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("photo0.jpg")
        func jpeg(_ color: NSColor) throws -> Data {
            let context = try #require(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            let image = try #require(context.makeImage())
            return try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]))
        }
        var red = try jpeg(.red), blue = try jpeg(.blue)
        let count = max(red.count, blue.count)
        red.append(Data(count: count - red.count)); blue.append(Data(count: count - blue.count))
        let modified = Date(timeIntervalSince1970: 1_500_000_000)
        try red.write(to: url); try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let firstAsset = PhotoAsset(resources: [PhotoResource(url: url, size: Int64(count), modified: modified)])
        let token = try await store.load(for: firstAsset).token
        try await store.save(.identity, for: firstAsset, token: token)
        let model = try await model(root: root, store: store)
        let otherID = try #require(model.photos.first { $0.id != firstAsset.id }?.id)
        model.setSelectedIDs([firstAsset.id, otherID], primary: firstAsset.id); model.startComparison()
        let session = try #require(model.comparison)
        try await wait { session.panes.allSatisfy { !$0.loading } }
        let oldAsset = session.activePane.asset, oldImage = try #require(session.activePane.image)
        #expect(oldAsset.id == firstAsset.id)
        let thumbnail = NSHostingView(rootView: Thumbnail(asset: oldAsset)); thumbnail.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: thumbnail.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = thumbnail; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func thumbnailIsBlue() -> Bool {
            thumbnail.layoutSubtreeIfNeeded()
            guard let bitmap = thumbnail.bitmapImageRepForCachingDisplay(in: thumbnail.bounds) else { return false }
            thumbnail.cacheDisplay(in: thumbnail.bounds, to: bitmap)
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
            return color.blueComponent > 0.8 && color.redComponent < 0.2
        }
        // Allow the first thumbnail task to populate its retained SwiftUI state.
        for _ in 0..<15 { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
        #expect(!thumbnailIsBlue())
        try blue.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        model.reload(); #expect(model.loading)
        try await wait { !model.loading && session.panes.allSatisfy { !$0.loading } }
        let updated = session.activePane.asset, newImage = try #require(session.activePane.image)
        #expect(updated.preferred.url == oldAsset.preferred.url && updated.preferred.size == oldAsset.preferred.size && updated.preferred.modified == oldAsset.preferred.modified)
        #expect(updated != oldAsset && newImage.cgImage !== oldImage.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: newImage.cgImage)
        let color = try #require(bitmap.colorAt(x: newImage.cgImage.width / 2, y: newImage.cgImage.height / 2)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > 0.8 && color.redComponent < 0.2)
        #expect(model.editWarnings[updated.id] != nil && model.edit(for: updated).isIdentity)
        thumbnail.rootView = Thumbnail(asset: updated)
        let deadline = ContinuousClock.now + .seconds(5)
        while !thumbnailIsBlue(), ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        #expect(thumbnailIsBlue(), "The retained thumbnail reloads when only the resource generation changes")
        session.cancel()
    }
    @Test func finalNativeWindowRenders() async throws {
        let preferences = preferences(); defer { restore(preferences) }
        guard let destination = ProcessInfo.processInfo.environment["PHOTOVIEWER_EDIT_CAPTURE_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await model(root: root, store: store)
        for state in ["landscape-thirds", "portrait-sixths", "loading", "error", "save-failure"] {
            model.select(model.photos[state == "portrait-sixths" ? 1 : 0].id); model.startEditing()
            let session = try #require(model.editor)
            try await wait { session.ready && !session.loading }
            if state == "loading" { session.image = nil; session.loading = true }
            else if state == "error" { session.image = nil; session.error = "Не удалось открыть синтетический снимок" }
            else {
                session.setAspect(state == "portrait-sixths" ? .threeTwo : .sixteenNine)
                session.draft.angleDegrees = state == "portrait-sixths" ? -18.4 : 12.3
                if state == "save-failure" { session.error = "Не удалось сохранить: нет доступа к хранилищу. Повторите попытку." }
            }
            model.grid = state == "portrait-sixths" ? .sixths : .thirds
            for size in [CGSize(width: 850, height: 560), CGSize(width: 1280, height: 800)] {
                let controller = NSHostingController(rootView: BrowserView(model: model).frame(width: size.width, height: size.height))
                let window = NSWindow(contentViewController: controller)
                window.styleMask = [.titled, .closable, .resizable]; window.setContentSize(size); window.makeKeyAndOrderFront(nil)
                for _ in 0..<12 {
                    controller.view.layoutSubtreeIfNeeded()
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                }
                let frame = try #require(window.contentView?.superview)
                let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: destination).appendingPathComponent("native-editor-\(state)-\(Int(size.width))x\(Int(size.height)).png"))
                window.contentViewController = nil; window.orderOut(nil)
            }
            _ = await model.finishEditing(save: false)
        }
        model.select(model.photos[0].id); model.startEditing()
        let saved = try #require(model.editor); try await wait { saved.ready && !saved.loading }
        saved.setAspect(.square); saved.draft.angleDegrees = 17.2
        #expect(await model.finishEditing(save: true))
        try await wait { model.preview != nil }
        for state in ["saved-gallery", "saved-columns", "saved-comparison"] {
            model.mode = state == "saved-columns" ? .columns : .gallery
            if state == "saved-columns" { try await wait { model.columns.allSatisfy { !$0.loading } && model.preview != nil } }
            if state == "saved-comparison" {
                model.setSelectedIDs(Set(model.photos.prefix(2).map(\.id)), primary: model.photos[0].id); model.startComparison()
                try await wait { model.comparison?.panes.allSatisfy { !$0.loading } == true }
            }
            model.grid = state == "saved-columns" ? .sixths : .thirds
            for size in [CGSize(width: 850, height: 560), CGSize(width: 1280, height: 800)] {
                let controller = NSHostingController(rootView: BrowserView(model: model).frame(width: size.width, height: size.height))
                let window = NSWindow(contentViewController: controller)
                window.styleMask = [.titled, .closable, .resizable]; window.setContentSize(size); window.makeKeyAndOrderFront(nil)
                for _ in 0..<12 {
                    controller.view.layoutSubtreeIfNeeded()
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                }
                let frame = try #require(window.contentView?.superview)
                let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: destination).appendingPathComponent("native-\(state)-\(Int(size.width))x\(Int(size.height)).png"))
                window.contentViewController = nil; window.orderOut(nil)
            }
        }
        model.comparison?.cancel()
    }
}

private actor EditImageGate {
    private var requests: [URL: [CheckedContinuation<RenderedImage, any Error>?]] = [:]
    func load(_ resource: PhotoResource) async throws -> RenderedImage {
        try await withCheckedThrowingContinuation { requests[resource.url, default: []].append($0) }
    }
    func count(_ url: URL) -> Int { requests[url]?.count ?? 0 }
    func resolve(_ url: URL, at index: Int, image: RenderedImage) {
        guard let continuation = requests[url]?[index] else { return }
        requests[url]?[index] = nil; continuation.resume(returning: image)
    }
}

private final class EditCatalogGate: CatalogSource, @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var blocked = false, hidden = false, didStart = false, didFinish = false
    var started: Bool { lock.withLock { didStart } }
    var finished: Bool { lock.withLock { didFinish } }
    func block() { lock.withLock { blocked = true; didStart = false; didFinish = false } }
    func release(hide: Bool) { lock.withLock { hidden = hide; blocked = false }; semaphore.signal() }
    func contents(of folder: URL) throws -> [CatalogEntry] {
        let wait = lock.withLock { if blocked { didStart = true }; return blocked }
        if wait { semaphore.wait(); lock.withLock { didFinish = true } }
        if lock.withLock({ hidden }) { return [] }
        return try FolderCatalog().contents(of: folder)
    }
}
