import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

@MainActor struct ZIPExportUITests {
    @Test func optionsSnapshotBusyAndRenderedStates() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in ["a.JPG", "a.RAF", "notes", ".hidden", "other.jpeg"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let model = BrowserModel()
        model.open(root)
        for _ in 0..<200 where model.entries.isEmpty || model.loading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.loading)
        let pair = try #require(model.photos.first { $0.asset?.isPair == true })
        model.select(pair.id)
        model.createZIP()
        #expect(model.busy && !model.canExportZIP && !model.canTrash)
        let session = try #require(model.zipSession)
        #expect(session.scope == .selected && session.resources.count == 2)
        session.selectScope(.selected)
        for _ in 0..<200 where session.progress != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.plan?.fileCount == 2)
        #expect(session.extensions == ["jpg", "raf"])
        session.extensions = ["jpg"]
        #expect(session.plan?.fileCount == 1 && session.plan?.byteCount == 5)
        session.extensions = []; session.explicitNone = true
        #expect(!session.canCreate)
        session.selectScope(.whole)
        for _ in 0..<200 where session.progress != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.plan?.fileCount == 4)
        #expect(session.scan?.groups.first { $0.extensionName.isEmpty }?.count == 1)
        for width in [850.0, 1180.0] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: ZIPExportView(session: session).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_ZIP_CAPTURE_DIR"] {
                try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try capture(window, to: URL(fileURLWithPath: directory).appendingPathComponent("zip-options-\(Int(width)).png"))
                session.progress = ZIPProgress(stage: .preparing, completed: 2, total: 5)
                try await Task.sleep(for: .milliseconds(30))
                window.contentView?.layoutSubtreeIfNeeded()
                try capture(window, to: URL(fileURLWithPath: directory).appendingPathComponent("zip-progress-\(Int(width)).png"))
                session.progress = nil
            }
            window.orderOut(nil)
        }
        session.result = root.appendingPathComponent("Photos.zip")
        let successWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        successWindow.appearance = NSAppearance(named: .darkAqua)
        successWindow.contentView = NSHostingView(rootView: ZIPExportView(session: session).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        successWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(30))
        successWindow.contentView?.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_ZIP_CAPTURE_DIR"] {
            try capture(successWindow, to: URL(fileURLWithPath: directory).appendingPathComponent("zip-success-sheet.png"))
        }
        successWindow.orderOut(nil)
        session.cancel()
        #expect(!model.busy && model.zipSession == nil)
    }
    private func capture(_ window: NSWindow, to url: URL) throws {
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
