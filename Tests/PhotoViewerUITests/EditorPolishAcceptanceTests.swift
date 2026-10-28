import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct EditorPolishAcceptanceTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    private func settle(_ view: NSView) async {
        for _ in 0..<16 {
            view.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    private func fixture() throws -> (URL, PhotoEditStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorPolishAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 180, height: 400))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 180, y: 0, width: 420, height: 400))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 40, y: 40, width: 70, height: 100))
        let image = try #require(context.makeImage())
        let bytes = try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]))
        try bytes.write(to: root.appendingPathComponent("asymmetric-editor-photo.jpg"))
        return (root, PhotoEditStore(folder: root, storageURL: root.appendingPathComponent("recipes/edits.json")))
    }
    @Test func doubleMirrorOfPersistedDecimalCropDoesNotCreateUnsavedChanges() async throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let asset = PhotoAsset(resources: [PhotoResource(url: root.appendingPathComponent("asymmetric-editor-photo.jpg"))])
        let recipe = PhotoEdit(quarterTurns: 1, angleDegrees: 13.7,
            crop: PhotoCrop(x: 0.1, y: 0.2, width: 0.3, height: 0.4), aspect: .free)
        try await store.save(recipe, for: asset, token: store.load(for: asset).token)
        let session = EditorSession(asset: asset, showsRAW: false, initial: .identity, store: store)
        session.start(); try await wait { session.ready && session.image != nil }
        #expect(!session.dirty)
        session.mirrorHorizontally(); session.mirrorHorizontally()
        #expect(abs(session.draft.crop.x - session.original.crop.x) < 1e-14)
        #expect(session.draft.quarterTurns == session.original.quarterTurns && session.draft.angleDegrees == session.original.angleDegrees)
        #expect(!session.dirty, "A visual no-op must not leave an unsaved-change prompt")
        session.draft.crop.x += 0.000001
        #expect(session.dirty, "Real crop edits must remain dirty")
        session.draft = session.original; session.draft.angleDegrees += 0.00000001
        #expect(session.dirty, "Angle edits must retain exact comparison")
        session.cancel()
    }
    @Test func nativePolishCapturesAndIntegratedSlider() async throws {
        _ = NSApplication.shared
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = BrowserModel(editStoreFactory: { _ in store })
        let metadata = model.showMetadata; model.showMetadata = false; defer { model.showMetadata = metadata }
        model.open(root); try await wait { !model.loading && model.photos.count == 1 }
        model.select(model.photos[0].id); model.startEditing()
        let session = try #require(model.editor)
        try await wait { session.ready && session.image != nil }
        for state in ["original-free", "mirrored-free", "mirrored-square", "portrait-2x3", "portrait-9x16"] {
            session.reset()
            if state != "original-free" { session.mirrorHorizontally() }
            if state == "mirrored-square" { session.setAspectChoice(.square) }
            if state == "portrait-2x3" { session.setAspectChoice(.twoThree) }
            if state == "portrait-9x16" { session.setAspectChoice(.nineSixteen) }
            #expect(session.canMirror)
            for dark in [false, true] {
                for size in [NSSize(width: 850, height: 560), NSSize(width: 1280, height: 800)] {
                    let controller = NSHostingController(rootView: BrowserView(model: model).frame(width: size.width, height: size.height))
                    let window = NSWindow(contentViewController: controller)
                    window.styleMask = [.titled, .closable, .resizable]
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.setContentSize(size); window.makeKeyAndOrderFront(nil)
                    defer { window.contentViewController = nil; window.orderOut(nil) }
                    await settle(controller.view)
                    let slider = try #require(descendants(controller.view, StraighteningSliderView.self).first)
                    #expect(slider.numberOfTickMarks == 0 && slider.isContinuous)
                    #expect(slider.isEnabled && slider.canEdit())
                    let angle = session.draft.angleDegrees
                    slider.setAccessibilityValue(NSNumber(value: 0.26))
                    #expect(session.draft.angleDegrees == 0.3)
                    #expect(slider.accessibilityPerformIncrement())
                    #expect(session.draft.angleDegrees == 0.4)
                    session.draft.angleDegrees = angle; await settle(controller.view)
                    let popup = try #require(descendants(controller.view, NSPopUpButton.self).first { $0.itemTitles.contains("Свободно") })
                    #expect(popup.itemTitles == EditorAspectChoice.allCases.map(\.title))
                    if state == "portrait-2x3" { #expect(popup.titleOfSelectedItem == "2:3") }
                    if state == "portrait-9x16" { #expect(popup.titleOfSelectedItem == "9:16") }
                    session.saving = true
                    #expect(!slider.accessibilityPerformIncrement(), "Saving lock must be read dynamically")
                    session.saving = false
                    if let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_EDITOR_POLISH_CAPTURE_DIR"] {
                        let frame = try #require(window.contentView?.superview)
                        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                        frame.cacheDisplay(in: frame.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        let name = "editor-\(state)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height)).png"
                        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                }
            }
        }
        _ = await model.finishEditing(save: false)
    }
}
