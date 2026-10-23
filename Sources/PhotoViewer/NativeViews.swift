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

struct IconGrid: NSViewRepresentable {
    let model: BrowserModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let collection = NSCollectionView()
        collection.collectionViewLayout = NSCollectionViewFlowLayout()
        collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.register(PhotoItem.self, forItemWithIdentifier: .init("photo"))
        collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        collection.backgroundColors = [.controlBackgroundColor]
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2; collection.addGestureRecognizer(doubleClick)
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
        let index = c.entries.firstIndex { $0.id == model.selection.id }
        collection.selectionIndexPaths = index.map { [IndexPath(item: $0, section: 0)] } ?? []
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
        var request: SelectionScrollRequest?
        init(_ model: BrowserModel) { self.model = model }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .init("photo"), for: indexPath) as! PhotoItem
            item.entry = entries[indexPath.item]; item.render(); return item
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !updating else { return }
            if let index = indexPaths.first?.item, entries.indices.contains(index) { model.select(entries[index].id) }
        }
        @objc func doubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let collection, let path = collection.indexPathForItem(at: gesture.location(in: collection)) else { return }
            model.activate(entries[path.item])
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
        let table = NSTableView(); table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 30
        for (id, title, width) in [("name", "Имя", 350.0), ("kind", "Тип", 120.0), ("modified", "Дата изменения", 180.0), ("size", "Размер", 110.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.activate)
        let scroll = SelectionScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator; c.model = model
        guard let table = c.table else { return }
        c.updating = true
        if c.entries != model.entries { c.entries = model.entries; table.reloadData() }
        if let index = c.entries.firstIndex(where: { $0.id == model.selection.id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
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
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, entries.indices.contains(table.selectedRow) else { return }
            model.select(entries[table.selectedRow].id)
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let sort = CatalogSort(rawValue: key) else { return }
            if model.sort == sort { if model.ascending != descriptor.ascending { model.setSort(sort) } }
            else { model.setSort(sort); if model.ascending != descriptor.ascending { model.setSort(sort) } }
        }
        @objc func activate() { guard let table, entries.indices.contains(table.clickedRow) else { return }; model.activate(entries[table.clickedRow]) }
    }
}

private struct ColumnScrollGeometry: Equatable {
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
}

struct ColumnBrowser: View {
    @Bindable var model: BrowserModel
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
                        List(model.entries, selection: Binding(get: { model.selection.id }, set: { model.select($0) })) { entry in
                            Label(entry.name, systemImage: entry.isFolder ? "folder" : "photo")
                                .id(entry.id).tag(entry.id)
                                .onTapGesture(count: 2) { model.activate(entry) }
                                .contextMenu { if entry.isFolder { Button("Открыть") { model.open(entry.url) } } }
                        }
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
                }.buttonStyle(.plain).listRowBackground(selected.contains(folder) ? Color.accentColor.opacity(0.15) : .clear)
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
