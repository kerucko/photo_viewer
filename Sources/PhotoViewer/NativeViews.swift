import AppKit
import SwiftUI
import PhotoCore

// A request changes only when navigation, selection or item order changes.
// Thumbnail/preview updates therefore never undo manual scrolling.
struct SelectionScrollRequest: Equatable {
    let location: BrowserModel.Location?
    let mode: ViewMode
    let id: String?
    let entries: [String]

    @MainActor init(_ model: BrowserModel) {
        location = model.location; mode = model.mode
        id = model.selection.id; entries = model.entries.map(\.id)
    }
}

@MainActor final class SelectionScrollView: NSScrollView {
    var revealSelection: (() -> Void)?
    override func layout() {
        super.layout()
        guard window != nil, contentSize.width > 0, contentSize.height > 0,
              let revealSelection else { return }
        self.revealSelection = nil
        documentView?.layoutSubtreeIfNeeded()
        revealSelection()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }
}

// Mouse gestures share the same deterministic selection rules across the
// AppKit views. Shift-arrow ranges use that same anchor as mouse gestures.
@MainActor fileprivate final class CatalogClickSelection {
    private var beforeClick: SelectionState?
    private var clickedID: String?
    func handle(_ id: String?, event: NSEvent, model: BrowserModel) {
        guard !model.busy else { return }
        if event.clickCount == 2, let id, let entry = model.entries.first(where: { $0.id == id }) {
            if clickedID == id, let beforeClick, beforeClick.ids.contains(id) {
                model.setSelectedIDs(beforeClick.ids, primary: id)
            }
            model.activate(entry)
        } else {
            beforeClick = model.selection; clickedID = id
            model.selectGesture(id, command: event.modifierFlags.contains(.command), shift: event.modifierFlags.contains(.shift))
        }
    }
}

@MainActor final class CatalogCollectionView: NSCollectionView {
    var clickSelection: ((Int?, NSEvent) -> Void)?
    var extendSelection: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.shift, .command, .control, .option]) == .shift,
           [123, 124, 125, 126].contains(event.keyCode) {
            extendSelection?([123, 126].contains(event.keyCode) ? -1 : 1)
        } else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        clickSelection?(indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item, event)
    }
}

@MainActor final class CatalogTableView: NSTableView {
    var clickSelection: ((Int?, NSEvent) -> Void)?
    var extendSelection: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.shift, .command, .control, .option]) == .shift,
           [123, 124, 125, 126].contains(event.keyCode) {
            extendSelection?([123, 126].contains(event.keyCode) ? -1 : 1)
        } else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        clickSelection?(row >= 0 ? row : nil, event)
    }
}

struct IconGrid: NSViewRepresentable {
    let model: BrowserModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let collection = CatalogCollectionView()
        collection.collectionViewLayout = NSCollectionViewFlowLayout()
        collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.register(PhotoItem.self, forItemWithIdentifier: .init("photo"))
        collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        collection.backgroundColors = [.controlBackgroundColor]
        collection.clickSelection = { [weak coordinator = context.coordinator] index, event in
            guard let coordinator else { return }
            coordinator.clicks.handle(index.flatMap { coordinator.entries.indices.contains($0) ? coordinator.entries[$0].id : nil }, event: event, model: coordinator.model)
            coordinator.syncSelection()
        }
        collection.extendSelection = { [weak coordinator = context.coordinator] delta in
            guard let coordinator else { return }
            coordinator.model.extendSelection(by: delta); coordinator.syncSelection()
        }
        let scroll = SelectionScrollView(); scroll.documentView = collection; scroll.hasVerticalScroller = true
        context.coordinator.collection = collection
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator; c.model = model
        guard let collection = c.collection else { return }
        if let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = NSSize(width: model.iconSize, height: model.iconSize + 40)
            layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            layout.minimumInteritemSpacing = 12; layout.minimumLineSpacing = 12
        }
        c.updating = true
        if c.entries != model.entries { c.entries = model.entries; collection.reloadData() }
        c.syncSelection()
        let request = SelectionScrollRequest(model)
        if c.request != request, let scroll = scroll as? SelectionScrollView {
            c.request = request
            scroll.revealSelection = { [weak c, weak collection] in
                guard let c, let collection, SelectionScrollRequest(c.model) == request,
                      let index = c.entries.firstIndex(where: { $0.id == request.id }) else { return }
                if let frame = collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
                    collection.scrollToVisible(frame)
                }
            }
            scroll.needsLayout = true
        }
        c.updating = false
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var model: BrowserModel
        var entries: [CatalogEntry] = []
        weak var collection: NSCollectionView?
        var updating = false
        fileprivate let clicks = CatalogClickSelection()
        var request: SelectionScrollRequest?
        init(_ model: BrowserModel) { self.model = model }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .init("photo"), for: indexPath) as! PhotoItem
            item.entry = entries[indexPath.item]; item.render(); return item
        }
        func syncSelection() {
            let wasUpdating = updating; updating = true
            collection?.selectionIndexPaths = Set(entries.indices.filter { model.selection.ids.contains(entries[$0].id) }.map { IndexPath(item: $0, section: 0) })
            updating = wasUpdating
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { readSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { readSelection() }
        private func readSelection() {
            guard !updating, let collection else { return }
            model.setSelectedIDs(Set(collection.selectionIndexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item].id : nil }), extending: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            syncSelection()
        }
    }
}

@MainActor final class PhotoItem: NSCollectionViewItem {
    var entry: CatalogEntry?
    override var isSelected: Bool { didSet { render() } }
    override func loadView() {
        let host = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
        // The collection layout owns the item frame. Keep this view for the
        // lifetime of the item, including selection changes and reuse.
        host.sizingOptions = []
        view = host
    }
    func render() {
        guard let entry else { return }
        let content = VStack(spacing: 6) {
            if let asset = entry.asset { Thumbnail(asset: asset) }
            else { Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(.blue).padding(20) }
            Text(entry.name).font(.caption).lineLimit(1)
            Text(entry.kind).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }.padding(8).background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        (view as? NSHostingView<AnyView>)?.rootView = AnyView(content)
    }
}

struct FileTable: NSViewRepresentable {
    let model: BrowserModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = CatalogTableView(); table.allowsMultipleSelection = true; table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 30
        for (id, title, width) in [("name", "Имя", 350.0), ("kind", "Тип", 120.0), ("modified", "Дата изменения", 180.0), ("size", "Размер", 110.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.clickSelection = { [weak coordinator = context.coordinator] index, event in
            guard let coordinator else { return }
            coordinator.clicks.handle(index.flatMap { coordinator.entries.indices.contains($0) ? coordinator.entries[$0].id : nil }, event: event, model: coordinator.model)
            coordinator.syncSelection()
        }
        table.extendSelection = { [weak coordinator = context.coordinator] delta in
            guard let coordinator else { return }
            coordinator.model.extendSelection(by: delta); coordinator.syncSelection()
        }
        let scroll = SelectionScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator; c.model = model
        guard let table = c.table else { return }
        c.updating = true
        if c.entries != model.entries { c.entries = model.entries; table.reloadData() }
        c.syncSelection()
        table.sortDescriptors = [NSSortDescriptor(key: model.sort.rawValue, ascending: model.ascending)]
        let request = SelectionScrollRequest(model)
        if c.request != request, let scroll = view as? SelectionScrollView {
            c.request = request
            scroll.revealSelection = { [weak c, weak table] in
                guard let c, let table, SelectionScrollRequest(c.model) == request,
                      let index = c.entries.firstIndex(where: { $0.id == request.id }) else { return }
                table.scrollRowToVisible(index)
            }
            scroll.needsLayout = true
        }
        c.updating = false
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var request: SelectionScrollRequest?
        fileprivate let clicks = CatalogClickSelection()
        var model: BrowserModel; var entries: [CatalogEntry] = []; weak var table: NSTableView?; var updating = false
        init(_ model: BrowserModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let entry = entries[row]
            let field = NSTextField(labelWithString: "")
            switch tableColumn?.identifier.rawValue {
            case "name": field.stringValue = (entry.isFolder ? "📁 " : "") + entry.name
            case "kind": field.stringValue = entry.kind
            case "modified": field.stringValue = entry.isFolder ? "—" : entry.modified.formatted(date: .numeric, time: .shortened)
            case "size": field.stringValue = entry.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            default: break
            }
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }
        func syncSelection() {
            let wasUpdating = updating; updating = true
            table?.selectRowIndexes(IndexSet(entries.indices.filter { model.selection.ids.contains(entries[$0].id) }), byExtendingSelection: false)
            updating = wasUpdating
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.setSelectedIDs(Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil }), extending: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            syncSelection()
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let sort = CatalogSort(rawValue: key) else { return }
            if model.sort == sort { if model.ascending != descriptor.ascending { model.setSort(sort) } }
            else { model.setSort(sort); if model.ascending != descriptor.ascending { model.setSort(sort) } }
        }
    }
}

private struct ColumnScrollGeometry: Equatable {
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
}

private struct ColumnDoubleClickSelection {
    let ids: Set<String>
    let target: String
    let timestamp: TimeInterval
}

struct ColumnBrowser: View {
    @Bindable var model: BrowserModel
    @State private var doubleClickSelection: ColumnDoubleClickSelection?

    private func updateSelection(_ ids: Set<String>) {
        let event = NSApp.currentEvent
        if let event, [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount == 1, ids.count == 1,
           model.selection.ids.count > 1, let target = ids.first,
           event.modifierFlags.intersection([.command, .shift]).isEmpty {
            doubleClickSelection = ColumnDoubleClickSelection(ids: model.selection.ids, target: target, timestamp: event.timestamp)
        }
        let shift = event?.modifierFlags.contains(.shift) == true
        if !shift, event?.modifierFlags.contains(.command) == true {
            let changed = model.selection.ids.symmetricDifference(ids)
            if changed.count == 1 {
                model.selectGesture(changed.first, command: true)
                return
            }
        }
        model.setSelectedIDs(ids, extending: shift)
    }
    private func activate(_ entry: CatalogEntry) {
        if let saved = doubleClickSelection, saved.target == entry.id,
           let event = NSApp.currentEvent, event.timestamp - saved.timestamp <= NSEvent.doubleClickInterval {
            model.setSelectedIDs(saved.ids, primary: entry.id)
        }
        doubleClickSelection = nil
        model.activate(entry)
    }
    var body: some View {
        HSplitView {
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    // Parent columns contain their immediate subfolders; no recursive scan.
                    ForEach(Array(model.ancestors.dropLast()), id: \.path) { parent in
                        FolderColumn(parent: parent, selected: model.ancestors, model: model)
                        Divider()
                    }
                    VStack(alignment: .leading) {
                        Text(model.folder?.lastPathComponent ?? "Папка").font(.headline).padding(10)
                        ScrollViewReader { selectionProxy in
                        List(model.entries, selection: Binding(get: { model.selection.ids }, set: { updateSelection($0) })) { entry in
                            Label(entry.name, systemImage: entry.isFolder ? "folder" : "photo")
                                .id(entry.id).tag(entry.id)
                                .onTapGesture(count: 2) { activate(entry) }
                                .contextMenu { if entry.isFolder { Button("Открыть") { model.open(entry.url) } } }
                        }
                        .disabled(model.busy)
                        .onChange(of: SelectionScrollRequest(model), initial: true) { _, request in
                            if let id = request.id, request.entries.contains(id) {
                                selectionProxy.scrollTo(id)
                            }
                        }
                        }
                    }.frame(width: 250).id("current-folder")
                }
            }
            // Wait for actual content and viewport geometry. Scroll offset is
            // deliberately excluded, so manual horizontal scrolling stays put.
            .onScrollGeometryChange(for: ColumnScrollGeometry.self) { geometry in
                ColumnScrollGeometry(contentWidth: geometry.contentSize.width, viewportWidth: geometry.containerSize.width)
            } action: { _, geometry in
                if geometry.contentWidth > 0, geometry.viewportWidth > 0 {
                    proxy.scrollTo("current-folder", anchor: .trailing)
                }
            }
            }.id(model.folder).frame(minWidth: 260)
            PreviewPane(model: model).frame(minWidth: 280)
        }
    }
}

struct FolderColumn: View {
    let parent: URL
    let selected: [URL]
    let model: BrowserModel
    @State private var folders: [URL] = []
    var body: some View {
        VStack(alignment: .leading) {
            Text(parent.path == "/" ? "Mac" : parent.lastPathComponent).font(.headline).padding(10)
            List(folders, id: \.path) { folder in
                Button { model.open(folder) } label: {
                    HStack { Label(folder.lastPathComponent, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right") }
                }.buttonStyle(.plain)
                    .help("Открыть папку «\(folder.lastPathComponent)»")
                    .listRowBackground(selected.contains(folder) ? Color.accentColor.opacity(0.15) : .clear)
            }
        }.frame(width: 190)
        .task(id: parent) {
            let root = parent
            folders = await Task.detached {
                let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }.value
        }
    }
}

struct ZoomCanvas: NSViewRepresentable {
    let image: CGImage
    @Binding var state: ViewportState
    func makeNSView(context: Context) -> CanvasView { CanvasView() }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.image = image; view.viewport = state
        view.onChange = { state = $0 }; view.needsDisplay = true
    }
}

@MainActor final class CanvasView: NSView {
    var image: CGImage?
    var viewport = ViewportState()
    var onChange: ((ViewportState) -> Void)?
    private var lastPoint: NSPoint?
    override var acceptsFirstResponder: Bool { true }
    override var wantsDefaultClipping: Bool { true }
    private var fit: CGFloat {
        guard let image else { return 1 }
        return min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
    }
    private var scale: CGFloat { viewport.scale.map { $0 / (window?.backingScaleFactor ?? 2) } ?? fit * viewport.fitMultiplier }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(x: (bounds.width - size.width) / 2 + viewport.offset.width, y: (bounds.height - size.height) / 2 + viewport.offset.height, width: size.width, height: size.height)
        context.interpolationQuality = .high; context.draw(image, in: rect)
    }
    override func mouseDown(with event: NSEvent) { lastPoint = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let lastPoint { viewport.offset.width -= point.x - lastPoint.x; viewport.offset.height -= point.y - lastPoint.y; publish() }
        lastPoint = point
    }
    override func mouseUp(with event: NSEvent) { lastPoint = nil }
    override func scrollWheel(with event: NSEvent) { viewport.offset.width += event.scrollingDeltaX; viewport.offset.height -= event.scrollingDeltaY; publish() }
    override func magnify(with event: NSEvent) {
        viewport.scale = min(8, max(0.05, (viewport.scale ?? fit * viewport.fitMultiplier * (window?.backingScaleFactor ?? 2)) * (1 + event.magnification)))
        publish()
    }
    private func publish() { onChange?(viewport); needsDisplay = true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsDisplay = true }
}
