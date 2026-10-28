import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct EditorPolishTests {
    @Test func integerBoundariesBothSignsDirectionsAndSkippedValues() {
        var tracker = AngleBoundaryTracker()
        do { let crossed = tracker.update(1); #expect(!crossed) } // Programmatic changes outside tracking stay silent.
        tracker.begin(at: 0)
        do { let crossed = tracker.update(0.1); #expect(!crossed) }
        do { let crossed = tracker.update(0.9); #expect(!crossed) }
        do { let crossed = tracker.update(1); #expect(crossed) }
        do { let crossed = tracker.update(1); #expect(!crossed) }
        do { let crossed = tracker.update(1.1); #expect(!crossed) }
        do { let crossed = tracker.update(1); #expect(crossed) }
        do { let crossed = tracker.update(-0.3); #expect(crossed) } // Cross zero downward.
        do { let crossed = tracker.update(-0.9); #expect(!crossed) }
        do { let crossed = tracker.update(-1); #expect(crossed) }
        do { let crossed = tracker.update(-1.1); #expect(!crossed) }
        do { let crossed = tracker.update(-1); #expect(crossed) }
        do { let crossed = tracker.update(0); #expect(crossed) }
        do { let crossed = tracker.update(15.7); #expect(crossed) } // One incoming change yields one alignment event.
        tracker.end()
        do { let crossed = tracker.update(-10); #expect(!crossed) }
        tracker.begin(at: -0.1)
        do { let crossed = tracker.update(0); #expect(crossed) }
    }
    @Test func roundingPreservesTenthsWithoutIntegerSnappingAndClamps() {
        #expect(AngleBoundaryTracker.rounded(0.96) == 1)
        #expect(AngleBoundaryTracker.rounded(1.16) == 1.2)
        #expect(AngleBoundaryTracker.rounded(-1.16) == -1.2)
        #expect(AngleBoundaryTracker.rounded(100) == 45)
        #expect(AngleBoundaryTracker.rounded(-100) == -45)
    }
    @Test func nativeSliderHasNoTicksAndKeyboardAccessibilityRemainPrecise() async throws {
        var angle = 0.0, enabled = true, feedback = 0
        let host = NSHostingView(rootView: StraighteningSlider(value: Binding(get: { angle }, set: { angle = $0 }), canEdit: { enabled }, haptic: { feedback += 1 }))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 30)
        host.layoutSubtreeIfNeeded()
        func slider(_ view: NSView) -> StraighteningSliderView? {
            (view as? StraighteningSliderView) ?? view.subviews.lazy.compactMap { slider($0) }.first
        }
        let control = try #require(slider(host))
        #expect(control.numberOfTickMarks == 0 && control.isContinuous)
        #expect(control.minValue == -45 && control.maxValue == 45)
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        control.keyDown(with: right)
        #expect(angle == 0.1 && feedback == 0)
        control.setAccessibilityValue(NSNumber(value: -1.26))
        #expect(angle == -1.3 && feedback == 0)
        #expect(control.accessibilityPerformIncrement())
        #expect(angle == -1.2 && feedback == 0)
        #expect(control.accessibilityPerformDecrement())
        #expect(angle == -1.3 && feedback == 0)
        control.setAccessibilityValue(NSNumber(value: 99))
        #expect(angle == 45 && feedback == 0)
        enabled = false
        control.keyDown(with: right)
        control.setAccessibilityValue(NSNumber(value: 0))
        #expect(angle == 45 && feedback == 0)
        // Programmatic refresh never calls the slider action or alignment feedback.
        control.doubleValue = -3
        #expect(angle == 45 && feedback == 0)
    }
    @Test func explicitAspectChoicesRestoreOldRecipesWithoutSchemaCases() {
        #expect(EditorAspectChoice.allCases.map(\.title) == ["Свободно", "Исходные", "1:1", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16"])
        for choice in EditorAspectChoice.allCases {
            let recipe = PhotoEdit(aspect: choice.aspect, portrait: choice.portrait)
            #expect(EditorAspectChoice(edit: recipe) == choice)
        }
        #expect(EditorAspectChoice(edit: PhotoEdit(aspect: .threeTwo, portrait: true)) == .twoThree)
        #expect(EditorAspectChoice(edit: PhotoEdit(aspect: .original, portrait: true)) == .original)
    }
    @Test func freeAndSquareMirrorSaveResetAndOriginalOrientation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorPolish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 40, height: 60, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(context.makeImage())
        let bytes = try #require(NSBitmapImageRep(cgImage: pixels).representation(using: .jpeg, properties: [:]))
        let url = root.appendingPathComponent("portrait.jpg"); try bytes.write(to: url)
        let store = PhotoEditStore(folder: root, storageURL: root.appendingPathComponent("recipes.json"))
        let asset = PhotoAsset(resources: [PhotoResource(url: url)])
        let rendered = RenderedImage(cgImage: pixels)
        func opened() async throws -> EditorSession {
            let session = EditorSession(asset: asset, showsRAW: false, initial: .identity, store: store, loader: { _ in rendered })
            #expect(!session.canMirror)
            session.start()
            let deadline = ContinuousClock.now + .seconds(3)
            while (!session.ready || session.image == nil), ContinuousClock.now < deadline { await Task.yield() }
            try #require(session.ready && session.image != nil)
            return session
        }
        let session = try await opened()
        #expect(session.draft.aspect == .free && session.canMirror)
        session.mirrorHorizontally(); #expect(session.draft.isMirroredHorizontally)
        session.saving = true; session.mirrorHorizontally()
        #expect(session.draft.isMirroredHorizontally && !session.canMirror)
        session.saving = false
        session.setAspectChoice(.square); #expect(session.canMirror)
        session.mirrorHorizontally(); #expect(!session.draft.isMirroredHorizontally)
        session.setAspectChoice(.twoThree)
        #expect(session.aspectChoice == .twoThree && session.draft.portrait)
        session.setAspectChoice(.original)
        #expect(session.aspectChoice == .original && session.draft.portrait)
        session.setAspectChoice(.threeFour); session.mirrorHorizontally()
        #expect(await session.save())
        let reopened = try await opened()
        #expect(reopened.aspectChoice == .threeFour && reopened.draft.isMirroredHorizontally)
        reopened.reset()
        #expect(reopened.draft == .identity && !reopened.draft.isMirroredHorizontally)
        #expect(await reopened.save())
        #expect(try await store.load(for: asset).edit == .identity)
    }

    @Test func dirtyIgnoresOnlyCropRoundoffAndKeepsOtherFieldsExact() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorPolishDirty-\(UUID().uuidString)")
        let asset = PhotoAsset(resources: [PhotoResource(url: root.appendingPathComponent("photo.jpg"))])
        let original = PhotoEdit(crop: PhotoCrop(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let session = EditorSession(asset: asset, showsRAW: false, initial: original, store: PhotoEditStore(folder: root))
        session.draft.mirrorHorizontally(); session.draft.mirrorHorizontally()
        #expect(!session.dirty)
        session.draft = original; session.draft.angleDegrees = 1e-14
        #expect(session.dirty)
        session.draft = original; session.draft.crop.x += 1e-8
        #expect(session.dirty)
        session.draft = original; session.draft.portrait.toggle()
        #expect(session.dirty)
        session.draft = original; session.draft.aspect = .square
        #expect(session.dirty)
        session.draft = original; session.draft.isMirroredHorizontally.toggle()
        #expect(session.dirty)
        session.draft = original; session.draft.quarterTurns = 1
        #expect(session.dirty)
    }

}
