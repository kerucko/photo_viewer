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

struct ColumnBrowser: View {
    @Bindable var model: BrowserModel
    var body: some View {
        HSplitView {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(model.visibleColumns) { column in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(column.url.path == "/" ? "Mac" : column.url.lastPathComponent)
                                    .font(.headline).lineLimit(1).padding(10)
                                ColumnTable(model: model, column: column)
                                if column.loading { ProgressView().controlSize(.small).padding(8) }
                                else if let error = column.error {
                                    Text(error).font(.caption).foregroundStyle(.secondary).padding(10)
                                    Button("Повторить") { model.reload() }.padding(.bottom, 8)
                                } else if column.entries.isEmpty {
                                    Text("Папка пуста").font(.caption).foregroundStyle(.secondary).padding(10)
                                }
                            }.frame(width: 250).id(column.id)
                            if column.id != model.visibleColumns.last?.id { Divider() }
                        }
                    }
                }
                .onScrollGeometryChange(for: ColumnScrollGeometry.self) { geometry in
                    ColumnScrollGeometry(contentWidth: geometry.contentSize.width, viewportWidth: geometry.containerSize.width)
                } action: { _, geometry in
                    if geometry.contentWidth > 0, geometry.viewportWidth > 0,
                       let last = model.visibleColumns.last { proxy.scrollTo(last.id, anchor: .trailing) }
                }
                .onChange(of: model.columnFocusRevision) { _, _ in
                    if let id = model.activeColumnID { proxy.scrollTo(id) }
                }
            }.frame(minWidth: 260)
            PreviewPane(model: model).frame(minWidth: 280)
        }.task { model.prepareColumns() }
    }
}

/// All columns use this table: hit testing belongs to the entire row, including
/// the icon, label and trailing blank space, rather than individual cell views.
@MainActor final class ColumnTableView: NSTableView {
    weak var browserModel: BrowserModel?
    var columnID = ""
    var clickRow: ((Int?, NSEvent) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let local = convert(point, from: superview)
        return row(at: local) >= 0 ? self : hit
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { browserModel?.focusColumn(columnID) }
        return accepted
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        clickRow?(row >= 0 ? row : nil, event)
    }
    override func keyDown(with event: NSEvent) {
        if let browserModel,
           BrowserKeyboard.handle(event, model: browserModel, firstResponder: self) { return }
        super.keyDown(with: event)
    }
}

struct ColumnTable: NSViewRepresentable {
    let model: BrowserModel
    let column: BrowserColumn
    func makeCoordinator() -> Coordinator { Coordinator(model, column: column) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = ColumnTableView()
        table.browserModel = model; table.columnID = column.id
        table.headerView = nil; table.rowHeight = 30; table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let name = NSTableColumn(identifier: .init("entry")); name.width = 250
        table.addTableColumn(name)
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.clickRow = { [weak coordinator = context.coordinator] row, event in coordinator?.click(row, event: event) }
        let scroll = SelectionScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model; coordinator.column = column
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        if coordinator.entries != column.entries { coordinator.entries = column.entries; table.reloadData() }
        coordinator.syncSelection()
        coordinator.updating = false
        let selection = model.columnSelection(column)
        let request = ColumnRevealRequest(mode: model.mode, ids: selection, entries: column.entries.map(\.id))
        if coordinator.revealRequest != request, let scroll = scroll as? SelectionScrollView {
            coordinator.revealRequest = request
            scroll.revealSelection = { [weak table, weak coordinator] in
                guard let table, let coordinator, coordinator.revealRequest == request,
                      let index = coordinator.entries.firstIndex(where: { $0.id == coordinator.model.selection.id && selection.contains($0.id) })
                        ?? coordinator.entries.firstIndex(where: { selection.contains($0.id) }) else { return }
                table.scrollRowToVisible(index)
            }
            scroll.needsLayout = true
        }
        if model.activeColumnID == column.id, coordinator.focusRevision != model.columnFocusRevision {
            coordinator.focusRevision = model.columnFocusRevision
            if model.columnFocusRevision > 0, let window = table.window,
               !(window.firstResponder is NSTextView), NSApp.modalWindow == nil {
                window.makeFirstResponder(table)
            }
        }
    }
    struct ColumnRevealRequest: Equatable {
        let mode: ViewMode
        let ids: Set<String>
        let entries: [String]
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var model: BrowserModel
        var column: BrowserColumn
        var entries: [CatalogEntry] = []
        weak var table: ColumnTableView?
        var updating = false
        var revealRequest: ColumnRevealRequest?
        var focusRevision: Int?
        private var beforeClick: Set<String>?
        private var clickedID: String?
        init(_ model: BrowserModel, column: BrowserColumn) { self.model = model; self.column = column }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let entry = entries[row]
            let cell = NSTableCellView()
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: entry.isFolder ? "folder.fill" : "photo", accessibilityDescription: entry.kind)
            image.contentTintColor = entry.isFolder ? .systemBlue : .secondaryLabelColor
            let label = NSTextField(labelWithString: entry.name)
            label.lineBreakMode = .byTruncatingMiddle
            image.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image); cell.addSubview(label); cell.imageView = image; cell.textField = label
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        func syncSelection() {
            let saved = updating; updating = true
            let selected = model.columnSelection(column)
            table?.selectRowIndexes(IndexSet(entries.indices.filter { selected.contains(entries[$0].id) }), byExtendingSelection: false)
            updating = saved
        }
        func click(_ row: Int?, event: NSEvent) {
            let id = row.flatMap { entries.indices.contains($0) ? entries[$0].id : nil }
            var restored: Set<String>?
            if event.clickCount == 2, clickedID == id, let id, beforeClick?.contains(id) == true { restored = beforeClick }
            if event.clickCount == 1 {
                beforeClick = column.url == model.folder || model.columns.isEmpty ? model.selection.ids : nil
                clickedID = id
            }
            model.clickColumn(column.id, entryID: id, command: event.modifierFlags.contains(.command),
                              shift: event.modifierFlags.contains(.shift), doubleClick: event.clickCount == 2, restoring: restored)
            syncSelection()
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            // Accessibility/native selection actions use the same model transition.
            let ids = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil }
            if let id = ids.first { model.clickColumn(column.id, entryID: id) }
            else { model.clickColumn(column.id, entryID: nil) }
            syncSelection()
        }
    }
}

struct ZoomCanvas: NSViewRepresentable {
    let image: CGImage
    @Binding var state: ViewportState
    @Environment(\.isEnabled) private var isEnabled
    var canInteract: (() -> Bool)? = nil
    var onActivate: (() -> Void)? = nil
    var onGeometry: ((CGSize, CGFloat) -> Void)? = nil
    var onMagnify: ((Double) -> Void)? = nil
    func makeNSView(context: Context) -> CanvasView { CanvasView() }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.image = image; view.viewport = state
        view.canInteract = { isEnabled && (canInteract?() ?? true) }
        view.onChange = { state = $0 }; view.onActivate = onActivate
        view.onGeometry = onGeometry; view.onMagnify = onMagnify
        view.reportGeometry(); view.needsDisplay = true
    }
}

@MainActor final class CanvasView: NSView {
    var image: CGImage?
    var viewport = ViewportState()
    var canInteract: () -> Bool = { true }
    var onChange: ((ViewportState) -> Void)?
    var onActivate: (() -> Void)?
    var onGeometry: ((CGSize, CGFloat) -> Void)?
    var onMagnify: ((Double) -> Void)?
    func reportGeometry() { onGeometry?(bounds.size, window?.backingScaleFactor ?? 2) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reportGeometry() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); reportGeometry() }
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
    override func mouseDown(with event: NSEvent) { guard canInteract() else { lastPoint = nil; return }; onActivate?(); lastPoint = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard canInteract() else { lastPoint = nil; return }
        let point = convert(event.locationInWindow, from: nil)
        if let lastPoint { viewport.offset.width -= point.x - lastPoint.x; viewport.offset.height -= point.y - lastPoint.y; publish() }
        lastPoint = point
    }
    override func mouseUp(with event: NSEvent) { lastPoint = nil }
    override func scrollWheel(with event: NSEvent) { guard canInteract() else { return }; onActivate?(); viewport.offset.width += event.scrollingDeltaX; viewport.offset.height -= event.scrollingDeltaY; publish() }
    override func magnify(with event: NSEvent) {
        guard canInteract() else { return }
        if let onMagnify { onMagnify(1 + event.magnification); return }
        viewport.scale = min(8, max(0.05, (viewport.scale ?? fit * viewport.fitMultiplier * (window?.backingScaleFactor ?? 2)) * (1 + event.magnification)))
        publish()
    }
    private func publish() { onChange?(viewport); needsDisplay = true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reportGeometry(); needsDisplay = true }
}

/// Capture modifiers at native mouseDown, before SwiftUI can defer gesture delivery.
struct GalleryThumbnailClickTarget: NSViewRepresentable {
    let model: BrowserModel
    let entryID: String
    func makeNSView(context: Context) -> GalleryThumbnailClickView { GalleryThumbnailClickView() }
    func updateNSView(_ view: GalleryThumbnailClickView, context: Context) {
        view.model = model; view.entryID = entryID
        view.setAccessibilityLabel(model.entries.first { $0.id == entryID }?.name)
        view.setAccessibilityValue(model.selection.ids.contains(entryID) ? "Выбрано" : "")
    }
}

@MainActor final class GalleryThumbnailClickView: NSView {
    weak var model: BrowserModel?
    var entryID = ""
    private var beforeClick: SelectionState?
    private var clickedID: String?
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard let model, !model.busy else { return false }
        model.selectGesture(entryID); return true
    }
    override func mouseDown(with event: NSEvent) {
        guard let model, !model.busy,
              let entry = model.entries.first(where: { $0.id == entryID }) else { return }
        window?.makeFirstResponder(self)
        if model.comparison != nil {
            model.selectGesture(entryID); return
        }
        if event.clickCount == 2 {
            if clickedID == entryID, let beforeClick, beforeClick.ids.contains(entryID), !entry.isFolder {
                model.setSelectedIDs(beforeClick.ids, primary: entryID)
            }
            model.activate(entry)
        } else {
            beforeClick = model.selection; clickedID = entryID
            model.selectGesture(entryID, command: event.modifierFlags.contains(.command))
        }
    }
}
