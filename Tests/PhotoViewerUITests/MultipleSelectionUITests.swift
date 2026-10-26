import AppKit
import SwiftUI
import Testing
import PhotoCore
@testable import PhotoViewer

@MainActor @Suite(.serialized) struct MultipleSelectionUITests {
    private func model() -> BrowserModel {
        let model = BrowserModel()
        model.entries = (0..<20).map { index in
            let url = URL(fileURLWithPath: "/synthetic/photo-\(index).jpg")
            let resources = index == 2 ? [PhotoResource(url: url), PhotoResource(url: url.deletingPathExtension().appendingPathExtension("raf"))] : [PhotoResource(url: url)]
            return CatalogEntry(url: url, asset: PhotoAsset(resources: resources))
        }
        return model
    }
    private func find<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
        if let result = root as? T { return result }
        return root.subviews.lazy.compactMap { find($0, type) }.first
    }
    private func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    @Test func modelPreservesGroupAcrossModesAndRefreshAndSnapshotsPairs() {
        let model = model()
        let ids = model.entries.map(\.id)
        model.selectGesture(ids[2])
        model.selectGesture(ids[4], command: true)
        let snapshot = model.selectedAssets
        #expect(snapshot.count == 2 && snapshot.flatMap(\.resources).count == 3)
        #expect(model.canTrash)
        model.activate(model.entries[2])
        #expect(model.mode == .gallery && model.selection.ids == [ids[2], ids[4]])
        #expect(model.selection.id == ids[2])
        model.toggleGallery()
        #expect(model.selection.ids == [ids[2], ids[4]])
        model.setSort(.name)
        #expect(model.selection.ids == [ids[2], ids[4]])
        model.entries.removeAll { $0.id == ids[2] }
        model.reconcileSelection()
        #expect(model.selection.ids == [ids[4]])
        model.select(nil)
        model.reconcileSelection()
        #expect(model.selection.ids.isEmpty)
        #expect(snapshot.count == 2) // The confirmed operation's value snapshot stays frozen.
        model.mode = .icons
        model.entries.insert(CatalogEntry(url: URL(fileURLWithPath: "/synthetic/folder")), at: 0)
        model.selectAllPhotos()
        #expect(model.selection.ids.count == 19)
        #expect(!model.selection.ids.contains(model.entries[0].id))
        model.busy = true
        let captured = model.selection.ids
        model.select(nil); model.selectAllPhotos(); model.activate(model.entries[0]); model.toggleGallery()
        #expect(model.selection.ids == captured)
        #expect(!model.canTrash)
    }

    @Test func batchConfirmationListsEveryResourceWithoutMovingFiles() throws {
        let model = model()
        model.mode = .list
        model.selectAllPhotos()
        let snapshot = model.selectedAssets
        let alert = BrowserModel.trashConfirmation(for: snapshot)
        #expect(alert.informativeText.contains("Снимков: 20. Файлов: 21."))
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(text.string.components(separatedBy: "\n").count == 21)
        #expect(text.string.contains("photo-2.jpg") && text.string.contains("photo-2.raf"))
        #expect(text.frame.height > scroll.frame.height)
        model.select(nil)
        #expect(snapshot.count == 20)
        #expect(!model.canTrash)
    }

    @Test func columnSetBindingUsesRangeEndpointAndKeepsAnchor() {
        let model = model()
        let ids = model.entries.map(\.id)
        model.select(ids[10])
        model.setSelectedIDs(Set(ids[2...10]), extending: true)
        #expect(model.selection.id == ids[2])
        #expect(model.selection.anchorID == ids[10])
        model.setSelectedIDs(Set(ids[7...10]), extending: true)
        #expect(model.selection.id == ids[7])
        #expect(model.selection.ids == Set(ids[7...10]))
        model.setSelectedIDs(Set(ids[7...10]).subtracting([ids[7]]))
        #expect(model.selection.id == ids[8])
    }

    @Test func columnShiftFolderIsSingletonAndKeyboardRoutingRespectsTextEditing() throws {
        let model = model()
        let photoIDs = model.entries.map(\.id)
        let folder = CatalogEntry(url: URL(fileURLWithPath: "/synthetic/folder"))
        model.entries.insert(folder, at: 0)
        model.select(photoIDs[4])
        model.setSelectedIDs(Set([folder.id] + Array(photoIDs[0...4])), extending: true)
        #expect(model.selection.ids == [folder.id] && model.selection.id == folder.id)
        #expect(!model.canTrash)
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        model.mode = .icons
        let commandA = try key(0, flags: .command)
        #expect(!BrowserKeyboard.handle(commandA, model: model, firstResponder: NSTextView()))
        #expect(model.selection.ids == [folder.id])
        #expect(BrowserKeyboard.handle(commandA, model: model, firstResponder: NSView()))
        #expect(model.selection.ids == Set(photoIDs))
        let right = try key(124)
        for mode in ViewMode.allCases {
            model.mode = mode
            model.setSelectedIDs([photoIDs[2], photoIDs[4]], primary: photoIDs[4])
            if mode == .columns {
                #expect(!BrowserKeyboard.handle(right, model: model, firstResponder: NSView()))
                let table = ColumnTableView(); table.browserModel = model
                table.columnID = model.visibleColumns[0].id
                #expect(BrowserKeyboard.handle(right, model: model, firstResponder: table))
                #expect(model.selection.ids == [photoIDs[2], photoIDs[4]]) // Right is folder navigation.
            } else {
                #expect(BrowserKeyboard.handle(right, model: model, firstResponder: NSView()))
                #expect(model.selection.ids == [photoIDs[5]])
            }
        }
        #expect(!BrowserKeyboard.handle(try key(124, flags: .shift), model: model, firstResponder: NSView()))
    }

    @Test func nativeMouseCommandShiftDeselectAndDoubleClick() async throws {
        for mode in [ViewMode.icons, .list] {
            let model = model(); model.mode = mode
            let ids = model.entries.map(\.id)
            let root = mode == .icons ? AnyView(IconGrid(model: model)) : AnyView(FileTable(model: model))
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            await settle(host)
            func click(_ index: Int, flags: NSEvent.ModifierFlags = [], count: Int = 1) throws {
                let view: NSView
                let rect: NSRect
                if mode == .icons {
                    let collection = try #require(find(host, CatalogCollectionView.self))
                    view = collection
                    rect = try #require(collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame)
                } else {
                    let table = try #require(find(host, CatalogTableView.self))
                    view = table; rect = table.rect(ofRow: index)
                }
                let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
                view.mouseDown(with: event)
            }
            try click(0); try click(2, flags: .command)
            #expect(model.selection.ids == [ids[0], ids[2]])
            try click(4, flags: .shift)
            #expect(model.selection.ids == Set(ids[2...4]))
            #expect(model.selection.id == ids[4])
            try click(3, flags: .command)
            #expect(model.selection.ids == [ids[2], ids[4]])
            try click(4); try click(4, flags: .command)
            #expect(model.selection.ids.isEmpty)
            try click(2); try click(4, flags: .command)
            func shiftArrow(_ key: UInt16) throws {
                let view: NSView = try #require(mode == .icons ? find(host, CatalogCollectionView.self) : find(host, CatalogTableView.self))
                let character = String(UnicodeScalar(key == 125 ? 0xF701 : 0xF700)!)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: key))
                view.keyDown(with: event)
            }
            try shiftArrow(125)
            #expect(model.selection.ids == Set(ids[4...5]))
            try shiftArrow(125)
            #expect(model.selection.ids == Set(ids[4...6]))
            try shiftArrow(126)
            #expect(model.selection.ids == Set(ids[4...5]))
            #expect(model.selection.anchorID == ids[4])
            try click(0); try click(2, flags: .command)
            try click(2); try click(2, count: 2)
            #expect(model.mode == .gallery)
            #expect(model.selection.ids == [ids[0], ids[2]])
            #expect(model.selection.id == ids[2])
        }
    }

    @Test func allThreeViewsRenderSameSelectedSet() async throws {
        let fixture = try await SelectionVisibilityTests().photoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        let ids = Set(model.entries[2...4].map(\.id))
        model.setSelectedIDs(ids, primary: model.entries[4].id)
        for mode in [ViewMode.icons, .list, .columns] {
            model.mode = mode
            let root: AnyView
            switch mode {
            case .icons: root = AnyView(IconGrid(model: model))
            case .list: root = AnyView(FileTable(model: model))
            default: root = AnyView(ColumnBrowser(model: model))
            }
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            await settle(host)
            if mode == .icons {
                let collection = try #require(find(host, NSCollectionView.self))
                #expect(collection.selectionIndexPaths == Set((2...4).map { IndexPath(item: $0, section: 0) }))
            } else {
                let table = try #require(find(host, NSTableView.self))
                #expect(table.selectedRowIndexes == IndexSet(2...4))
            }
            if let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_MULTI_CAPTURE_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("multi-\(mode.rawValue).png"))
            }
        }
    }
}
