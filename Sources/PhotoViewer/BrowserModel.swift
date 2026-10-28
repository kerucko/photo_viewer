import AppKit
import SwiftUI
import PhotoCore

@MainActor @Observable final class BrowserModel {
    enum Location: Hashable, Sendable {
        case folder(URL), library(URL)
        var url: URL { switch self { case .folder(let url), .library(let url): url } }
    }
    private(set) var location: Location?
    var folder: URL? { location?.url }
    var isLibrary: Bool { if case .library = location { true } else { false } }
    var libraryRoot: URL? = UserDefaults.standard.url(forKey: "libraryRoot")
    private var library: PhotoLibrary?
    var zipSession: ZIPExportSession?
    var canExportZIP: Bool { location != nil && !interactionLocked && !loading }
    func createZIP() {
        guard canExportZIP, let location else { return }
        beginOperation("Создание ZIP-архива…")
        zipSession = ZIPExportSession(location: location, assets: selectedAssets) { [weak self] in
            guard let self else { return }
            zipSession = nil; finishOperation()
        }
    }
    var editor: EditorSession?
    var interactionLocked: Bool { busy || editor != nil }
    var edits: [String: PhotoEdit] = [:]
    var editWarnings: [String: String] = [:]
    var editRevision = 0
    var grid = PhotoGrid(rawValue: UserDefaults.standard.string(forKey: "photoGrid") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(grid.rawValue, forKey: "photoGrid") }
    }
    private var editStores: [Location: PhotoEditStore] = [:]
    private var deferredReload = false
    private var previewRequest = UUID()
    var busy = false
    var operationTitle = ""
    var selectedAssets: [PhotoAsset] { entries.filter { selection.ids.contains($0.id) }.compactMap(\.asset) }
    var trashAssets: [PhotoAsset] { comparison.map { [$0.activePane.asset] } ?? selectedAssets }
    var showsRAW: Bool { editor?.showsRAW ?? comparison?.activePane.showsRAW ?? selection.showsRAW }
    var canTrash: Bool { !trashAssets.isEmpty && !interactionLocked && !loading }
    var canSelectAll: Bool { mode != .gallery && !photos.isEmpty && !interactionLocked }
    var canUp: Bool { !interactionLocked && !isLibrary && folder != nil && folder?.path != "/" }
    var entries: [CatalogEntry] = []
    var selection = SelectionState()
    var loading = false
    var error: String?
    var catalogIssues: [String] = []
    var preview: RenderedImage?
    var previewError: String?
    var previewLoading = false
    var comparison: ComparisonSession?
    var viewport = ViewportState()
    var showMetadata = UserDefaults.standard.bool(forKey: "showMetadata") {
        didSet { UserDefaults.standard.set(showMetadata, forKey: "showMetadata") }
    }
    var filmstripSize = FilmstripSize(rawValue: UserDefaults.standard.string(forKey: "filmstripSize") ?? "") ?? .medium {
        didSet { UserDefaults.standard.set(filmstripSize.rawValue, forKey: "filmstripSize") }
    }
    var iconSize: Double = UserDefaults.standard.object(forKey: "iconSize") as? Double ?? 150 {
        didSet { UserDefaults.standard.set(iconSize, forKey: "iconSize") }
    }
    var sort: CatalogSort = CatalogSort(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .name
    var ascending = UserDefaults.standard.object(forKey: "ascending") as? Bool ?? true
    private var history: [Location] = []
    private var historyIndex = -1
    private var folderRevision = 0
    private var selectFirstOnRefresh = false
    private var previewTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var priorMode: ViewMode = .icons
    private let catalog: any CatalogSource
    private let editStoreFactory: (Location) -> PhotoEditStore
    private(set) var columns: [BrowserColumn] = []
    private(set) var activeColumnID: String?
    private(set) var columnFocusRevision = 0
    private var columnTasks: [String: Task<Void, Never>] = [:]
    private var suspendedColumnIDs: Set<String> = []
    init(catalog: any CatalogSource = FolderCatalog(), editStoreFactory: @escaping (Location) -> PhotoEditStore = { location in
        PhotoEditStore(folder: location.url, libraryRoot: { if case .library(let root) = location { return root }; return nil }())
    }) {
        self.catalog = catalog; self.editStoreFactory = editStoreFactory
        selection.mode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .icons
    }
    var selected: CatalogEntry? { entries.first { $0.id == selection.id } }
    var selectedResource: PhotoResource? {
        if let editor { return editor.resource }
        if let comparison { return comparison.activePane.resource }
        guard let asset = selected?.asset else { return nil }
        return selection.showsRAW ? (asset.raw ?? asset.preferred) : asset.preferred
    }
    var canZoom: Bool { !interactionLocked && (comparison?.activePane.image != nil || preview != nil) && (mode == .gallery || mode == .columns) }
    var photos: [CatalogEntry] { entries.filter { !$0.isFolder } }
    var mode: ViewMode {
        get { selection.mode }
        set {
            guard !interactionLocked else { return }
            if comparison != nil { exitComparison() }
            let previous = selection.mode
            selection.mode = newValue; UserDefaults.standard.set(newValue.rawValue, forKey: "mode")
            if newValue == .columns { prepareColumns() }
            else if previous == .columns {
                cancelColumnTasks(); columns = []; activeColumnID = nil
                if loading { reload() }
            }
        }
    }
    var canBack: Bool { historyIndex > 0 }
    var canForward: Bool { historyIndex + 1 < history.count }
    var ancestors: [URL] {
        guard !isLibrary, var url = folder else { return [] }
        var result = [url]
        while url.path != "/" { url.deleteLastPathComponent(); result.insert(url, at: 0) }
        return result
    }
    func chooseFolder() {
        guard !interactionLocked else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Открыть"; panel.message = "Выберите папку с фотографиями"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, recordHistory: Bool = true) {
        navigate(.folder(url), recordHistory: recordHistory)
    }
    private func navigate(_ destination: Location, recordHistory: Bool = true) {
        guard !interactionLocked else { return }
        if recordHistory && location != destination {
            history = Array(history.prefix(historyIndex + 1)); history.append(destination); historyIndex = history.count - 1
        }
        if comparison != nil { exitComparison() }
        let changed = location != destination
        location = destination
        if case .library(let root) = destination {
            if library?.root != root { library = PhotoLibrary(root: root) }
        }
        if changed { entries = []; catalogIssues = []; select(nil); selectFirstOnRefresh = mode != .columns }
        if mode == .columns, !isLibrary {
            rebuildColumns(); return
        }
        cancelColumnTasks(); columns = []; activeColumnID = nil
        reload()
    }
    func back() { guard !interactionLocked, canBack else { return }; historyIndex -= 1; navigate(history[historyIndex], recordHistory: false) }
    func forward() { guard !interactionLocked, canForward else { return }; historyIndex += 1; navigate(history[historyIndex], recordHistory: false) }
    func up() { guard canUp, let folder else { return }; open(folder.deletingLastPathComponent()) }
    func reload() {
        if editor != nil { deferredReload = true; return }
        guard !interactionLocked else { return }
        if mode == .columns, !isLibrary, !columns.isEmpty {
            for column in columns { loadColumn(column.id) }; return
        }
        guard location != nil else { return }
        // Publish the pending state before yielding: callers must never observe
        // an empty newly opened catalog as a completed load.
        loading = true; error = nil
        Task { await refresh() }
    }
    private func refresh(nearest index: Int? = nil, comparisonTrash: (ComparisonTrashSnapshot, Bool)? = nil) async {
        if mode == .columns, !isLibrary, !columns.isEmpty {
            for column in columns { loadColumn(column.id, nearest: index) }; return
        }
        guard editor == nil, let location else { return }
        folderRevision += 1; let revision = folderRevision
        loading = true; error = nil
        let source = catalog
        do {
            let contents: [CatalogEntry]
            var issues: [String] = []
            switch location {
            case .folder(let folder): contents = try await Task.detached { try Self.directoryContents(source, of: folder) }.value
            case .library(let root):
                if library?.root != root { library = PhotoLibrary(root: root) }
                let snapshot = try await library!.snapshot()
                contents = snapshot.entries; issues = snapshot.issues
            }
            guard revision == folderRevision, editor == nil else { return }
            await loadEdits(for: contents, location: location, valid: { self.folderRevision == revision && self.location == location && self.editor == nil })
            guard revision == folderRevision, editor == nil else { return }
            catalogIssues = issues
            entries = FolderCatalog.sorted(contents, by: sort, ascending: ascending)
            loading = false
            if let (snapshot, succeeded) = comparisonTrash {
                completeComparisonTrash(snapshot: snapshot, succeeded: succeeded)
            }
            reconcileSelection(nearest: index, selectFirstIfEmpty: selectFirstOnRefresh)
            selectFirstOnRefresh = false
            loadPreview()
        } catch {
            guard revision == folderRevision, editor == nil else { return }
            if comparison != nil { endComparison() }
            entries = []; catalogIssues = []; selection.select(nil); loading = false
            self.error = "Папка недоступна. Проверьте подключение носителя и права доступа.\n\(error.localizedDescription)"
        }
    }
    @discardableResult func chooseLibrary() -> Bool {
        guard !interactionLocked else { return false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Выбрать библиотеку"
        panel.message = "Выберите или создайте папку для библиотеки. Здесь будут храниться копии фотографий, независимо от SD-карты."
        guard panel.runModal() == .OK, let root = panel.url else { return false }
        libraryRoot = root; UserDefaults.standard.set(root, forKey: "libraryRoot")
        navigate(.library(root)); return true
    }
    func openLibrary() {
        guard !interactionLocked else { return }
        if let libraryRoot { navigate(.library(libraryRoot)) } else { chooseLibrary() }
    }
    func chooseImport() {
        guard !interactionLocked else { return }
        if libraryRoot == nil && !chooseLibrary() { return }
        guard let root = libraryRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Импортировать"
        panel.message = "Выберите SD-карту или папку с фотографиями. JPG и RAF будут скопированы с сохранением оригиналов, включая вложенные папки."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let target: PhotoLibrary
        if let library, library.root == root { target = library }
        else { target = PhotoLibrary(root: root); library = target }
        beginOperation("Импорт фотографий…")
        Task {
            do {
                let report = try await target.importPhotos(from: source)
                finishOperation()
                if location == .library(root) { await refresh() }
                let alert = NSAlert()
                alert.messageText = "Импорт завершён"
                alert.informativeText = "Добавлено файлов: \(report.imported). Пропущено: \(report.skipped)." + (report.issues.isEmpty ? "" : "\n\n" + Self.summarizeIssues(report.issues))
                alert.addButton(withTitle: "Открыть библиотеку").toolTip = "Открыть библиотеку с импортированными фотографиями"
                alert.addButton(withTitle: "Закрыть").toolTip = "Закрыть отчёт об импорте"
                if alert.runModal() == .alertFirstButtonReturn { navigate(.library(root)) }
            } catch {
                finishOperation()
                showMessage("Не удалось импортировать", error.localizedDescription)
                if location == .library(root) { await refresh() }
            }
        }
    }
    func confirmTrash() {
        guard canTrash, location != nil else { return }
        // Capture the complete group before confirmation or asynchronous work.
        let assets = trashAssets
        let comparisonSnapshot = comparison.map { ComparisonTrashSnapshot(session: $0, photoIDs: photos.map(\.id)) }
        let alert = Self.trashConfirmation(for: assets)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let targetID = comparisonSnapshot?.asset.id ?? selection.id
        let index = photos.firstIndex { $0.id == targetID } ?? 0
        let managedRoot: URL?
        if case .library(let root)? = location { managedRoot = root } else { managedRoot = libraryRoot }
        let target = managedRoot.map { root in library?.root == root ? library! : PhotoLibrary(root: root) }
        beginOperation("Перемещение в Корзину…")
        Task {
            let report = await PhotoTrash.trash(assets) { asset in
                if let target, asset.resources.allSatisfy({ $0.url.standardizedFileURL.path.hasPrefix(target.root.standardizedFileURL.path + "/") }) {
                    return try await target.trash(asset)
                }
                return await Task.detached { PhotoTrash.trash(asset) }.value
            }
            if let comparisonSnapshot {
                // Keep native gestures and user actions locked through catalog reconciliation.
                await refresh(nearest: index, comparisonTrash: (comparisonSnapshot, report.failures.isEmpty))
                finishOperation(resumeColumns: false)
            } else {
                finishOperation(resumeColumns: false)
                await refresh(nearest: index)
            }
            if !report.failures.isEmpty {
                showMessage("Не все файлы перемещены в Корзину", "Перемещено: \(report.trashed.count).\n" + Self.summarizeIssues(report.failures))
            }
        }
    }
    static func trashConfirmation(for assets: [PhotoAsset]) -> NSAlert {
        let resources = assets.flatMap(\.resources)
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = assets.count == 1 ? "Переместить снимок в Корзину?" : "Переместить выбранные снимки в Корзину?"
        alert.informativeText = "Снимков: \(assets.count). Файлов: \(resources.count). Будут перемещены все перечисленные ресурсы, включая оба файла пар."
        let list = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        list.string = resources.map { $0.url.lastPathComponent }.joined(separator: "\n")
        list.isEditable = false; list.isSelectable = true; list.font = .systemFont(ofSize: 12)
        list.isHorizontallyResizable = false; list.isVerticallyResizable = true
        list.minSize = NSSize(width: 440, height: 160)
        list.maxSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
        list.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        scroll.documentView = list; scroll.hasVerticalScroller = true
        list.sizeToFit()
        alert.accessoryView = scroll
        alert.addButton(withTitle: "В Корзину").toolTip = "Переместить все перечисленные файлы выбранных снимков в системную Корзину"
        alert.addButton(withTitle: "Отмена").toolTip = "Закрыть подтверждение без перемещения файлов"
        return alert
    }
    private func beginOperation(_ title: String) {
        busy = true; operationTitle = title
        folderRevision += 1; loading = false
        suspendedColumnIDs = Set(columns.filter(\.loading).map(\.id))
        cancelColumnTasks()
        for index in columns.indices {
            columns[index].request = nil; columns[index].loading = false
        }
        previewTask?.cancel(); prefetchTask?.cancel()
        comparison?.cancel()
    }
    private func finishOperation(resumeColumns: Bool = true) {
        busy = false
        let pending = suspendedColumnIDs; suspendedColumnIDs = []
        if resumeColumns, mode == .columns, !isLibrary {
            for id in pending { loadColumn(id) }
        }
        loadPreview()
    }
    func showCatalogIssues() {
        showMessage("Некоторые файлы библиотеки недоступны", Self.summarizeIssues(catalogIssues))
    }
    static func summarizeIssues(_ issues: [String]) -> String {
        let visible = issues.prefix(12).joined(separator: "\n")
        return visible + (issues.count > 12 ? "\nИ ещё: \(issues.count - 12)." : "")
    }
    private func showMessage(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "OK").toolTip = "Закрыть сообщение"
        alert.runModal()
    }
    func setSort(_ field: CatalogSort) {
        guard !interactionLocked else { return }
        if sort == field { ascending.toggle() } else { sort = field; ascending = true }
        UserDefaults.standard.set(sort.rawValue, forKey: "sort"); UserDefaults.standard.set(ascending, forKey: "ascending")
        entries = FolderCatalog.sorted(entries, by: sort, ascending: ascending)
        for index in columns.indices {
            columns[index].entries = FolderCatalog.sorted(columns[index].entries, by: sort, ascending: ascending)
        }
    }
    private func changeSelection(_ change: (inout SelectionState) -> Void) {
        guard !interactionLocked else { return }
        let prior = selection.id
        change(&selection)
        if prior != selection.id { viewport = ViewportState(); loadPreview() }
    }
    func select(_ id: String?) {
        guard !interactionLocked else { return }
        if comparison != nil { if let id { replaceComparison(with: id) }; return }
        selectFirstOnRefresh = false
        changeSelection { $0.select(id) }
    }
    func selectGesture(_ id: String?, command: Bool = false, shift: Bool = false) {
        if comparison != nil { if let id { replaceComparison(with: id) }; return }
        guard let id, let entry = entries.first(where: { $0.id == id }) else { select(nil); return }
        let order = photos.map(\.id)
        changeSelection { selection in
            if entry.isFolder { selection.select(id) }
            else if shift { selection.extend(to: id, orderedIDs: order) }
            else if command {
                selection.retain(orderedIDs: order)
                selection.toggle(id, orderedIDs: order)
            } else { selection.select(id) }
        }
    }
    func setSelectedIDs(_ ids: Set<String>, primary: String? = nil, extending: Bool = false) {
        let valid = entries.filter { ids.contains($0.id) }
        let addedFolder = extending ? nil : valid.first { $0.isFolder && !selection.ids.contains($0.id) }
        let allowed = addedFolder.map { [$0] } ?? (valid.count > 1 ? valid.filter { !$0.isFolder } : valid)
        let order = entries.map(\.id)
        let added = allowed.last { !selection.ids.contains($0.id) }?.id
        if extending, let anchor = selection.anchorID ?? selection.id,
           let anchorIndex = order.firstIndex(of: anchor), !valid.isEmpty {
            let endpoint = valid.max {
                abs((order.firstIndex(of: $0.id) ?? 0) - anchorIndex) < abs((order.firstIndex(of: $1.id) ?? 0) - anchorIndex)
            }!.id
            selectGesture(endpoint, shift: true)
        } else {
            changeSelection { $0.replace(Set(allowed.map(\.id)), primary: primary ?? added, orderedIDs: order) }
        }
    }
    func selectAllPhotos() {
        guard canSelectAll else { return }
        let ids = photos.map(\.id)
        changeSelection { $0.replace(Set(ids), primary: $0.id, orderedIDs: ids) }
    }
    func reconcileSelection(nearest index: Int? = nil, selectFirstIfEmpty: Bool = false) {
        guard editor == nil else { return }
        if comparison != nil { reconcileComparison(); return }
        let hadSelection = !selection.ids.isEmpty
        let prior = selection.id
        selection.retain(orderedIDs: entries.map(\.id))
        if (hadSelection || selectFirstIfEmpty), selection.ids.isEmpty, !photos.isEmpty {
            selection.select(photos[min(index ?? 0, photos.count - 1)].id)
        }
        if prior != selection.id { viewport = ViewportState() }
    }
    func activate(_ entry: CatalogEntry) {
        guard !interactionLocked else { return }
        if comparison != nil, !entry.isFolder { replaceComparison(with: entry.id); return }
        if entry.isFolder { open(entry.url) }
        else {
            changeSelection { $0.focus(entry.id) }
            if mode != .gallery { priorMode = mode }
            mode = .gallery
        }
    }
    func toggleGallery() {
        guard !interactionLocked else { return }
        if comparison != nil { exitComparison() }
        if mode == .gallery { mode = priorMode }
        else if selected?.asset != nil { priorMode = mode; mode = .gallery }
    }
    func step(_ delta: Int) {
        if comparison != nil { stepComparison(delta); return }
        guard !photos.isEmpty else { return }
        let current = photos.firstIndex { $0.id == selection.id } ?? (delta > 0 ? -1 : photos.count)
        select(photos[min(max(current + delta, 0), photos.count - 1)].id)
    }
    func extendSelection(by delta: Int) {
        guard !interactionLocked, !photos.isEmpty else { return }
        let current = photos.firstIndex { $0.id == selection.id } ?? (delta > 0 ? -1 : photos.count)
        selectGesture(photos[min(max(current + delta, 0), photos.count - 1)].id, shift: true)
    }
    func toggleRAW() {
        guard !busy else { return }
        if let editor { editor.toggleRAW(); return }
        if let comparison { comparison.toggleRAW(); syncComparisonSelection(); return }
        guard selected?.asset?.isPair == true else { return }
        selection.toggleRAW(); viewport = ViewportState(); loadPreview()
    }
    private func loadPreview() {
        guard editor == nil else { return }
        if let comparison {
            previewTask?.cancel(); prefetchTask?.cancel(); preview = nil; previewLoading = false; previewError = nil
            if !busy { comparison.resume() }; return
        }
        previewTask?.cancel(); prefetchTask?.cancel(); preview = nil; previewError = nil; previewLoading = false
        guard let asset = selected?.asset else { return }
        let resource = selection.showsRAW ? (asset.raw ?? asset.preferred) : asset.preferred
        let revision = selection.revision
        let request = UUID(); previewRequest = request
        let edit = edits[asset.id] ?? .identity
        previewLoading = true
        previewTask = Task {
            do {
                let image = try await ImageService.shared.image(resource, maxPixel: nil, edit: edit)
                guard !Task.isCancelled, selection.accepts(revision), previewRequest == request, editor == nil else { return }
                preview = image; previewLoading = false
            } catch {
                guard !Task.isCancelled, selection.accepts(revision), previewRequest == request, editor == nil else { return }
                previewError = error.localizedDescription; previewLoading = false
            }
        }
        guard let index = photos.firstIndex(where: { $0.id == asset.id }) else { return }
        let neighbors = [index - 1, index + 1].filter { photos.indices.contains($0) }.compactMap { photos[$0].asset?.jpeg }
        prefetchTask = Task {
            for neighbor in neighbors {
                guard !Task.isCancelled else { return }
                _ = try? await ImageService.shared.image(neighbor, maxPixel: nil)
            }
        }
    }

    var canEdit: Bool { !interactionLocked && (comparison?.activePane.asset ?? selected?.asset) != nil }
    var activeEdit: PhotoEdit { selected.flatMap { edits[$0.id] } ?? .identity }
    var resultingSize: CGSize? {
        guard !activeEdit.isIdentity, let image = comparison?.activePane.image ?? preview else { return nil }
        return CGSize(width: image.cgImage.width, height: image.cgImage.height)
    }
    func edit(for asset: PhotoAsset) -> PhotoEdit { edits[asset.id] ?? .identity }
    private func store(for location: Location) -> PhotoEditStore {
        if let existing = editStores[location] { return existing }
        let created = editStoreFactory(location); editStores[location] = created; return created
    }
    private func loadEdits(for contents: [CatalogEntry], location: Location, valid: () -> Bool) async {
        let store = store(for: location)
        var loaded: [String: PhotoEdit] = [:], warnings: [String: String] = [:]
        for asset in contents.compactMap(\.asset) {
            do {
                let result = try await store.recipe(for: asset)
                loaded[asset.id] = result.edit
                if let warning = result.warning { warnings[asset.id] = warning }
            } catch { loaded[asset.id] = .identity; warnings[asset.id] = error.localizedDescription }
        }
        guard valid() else { return }
        edits.merge(loaded) { _, new in new }; editWarnings.merge(warnings) { _, new in new }
        for asset in contents.compactMap(\.asset) where warnings[asset.id] == nil { editWarnings[asset.id] = nil }
        editRevision += 1
    }
    func startEditing() {
        guard canEdit, let asset = comparison?.activePane.asset ?? selected?.asset else { return }
        if comparison != nil { endComparison() }
        if mode != .gallery { priorMode = mode; mode = .gallery }
        folderRevision += 1; previewRequest = UUID(); deferredReload = loading
        loading = false; cancelColumnTasks()
        previewTask?.cancel(); prefetchTask?.cancel()
        let store = location.map { self.store(for: $0) } ?? PhotoEditStore(folder: asset.preferred.url.deletingLastPathComponent())
        let session = EditorSession(asset: asset, showsRAW: selection.showsRAW, initial: edits[asset.id] ?? .identity, store: store)
        editor = session; session.start()
    }
    @discardableResult func finishEditing(save: Bool) async -> Bool {
        guard let session = editor, !session.saving else { return false }
        if save {
            guard await session.save(), editor === session else { return false }
            edits[session.asset.id] = session.draft; editWarnings[session.asset.id] = nil; editRevision += 1
        } else { session.cancel() }
        guard editor === session else { return false }
        if selection.showsRAW != session.showsRAW { selection.toggleRAW() }
        editor = nil; viewport = ViewportState(); loadPreview()
        if deferredReload { deferredReload = false; reload() }
        return true
    }
    enum EditorCloseChoice { case save, discard, cancel }
    func requestClose(choice: EditorCloseChoice? = nil, _ completion: @escaping @MainActor (Bool) -> Void) {
        guard let editor else { completion(true); return }
        guard !editor.saving else { completion(false); return }
        if !editor.dirty { Task { completion(await finishEditing(save: false)) }; return }
        let decision: EditorCloseChoice
        if let choice { decision = choice }
        else {
            let alert = NSAlert(); alert.messageText = "Сохранить правки снимка?"
            alert.informativeText = "Оригинальные файлы не изменяются."
            alert.addButton(withTitle: "Сохранить").toolTip = "Сохранить правки и продолжить закрытие"
            alert.addButton(withTitle: "Отбросить").toolTip = "Продолжить закрытие без сохранения правок"
            alert.addButton(withTitle: "Отмена").toolTip = "Вернуться к редактированию"
            switch alert.runModal() {
            case .alertFirstButtonReturn: decision = .save
            case .alertSecondButtonReturn: decision = .discard
            default: decision = .cancel
            }
        }
        switch decision {
        case .save: Task { completion(await finishEditing(save: true)) }
        case .discard: Task { completion(await finishEditing(save: false)) }
        case .cancel: completion(false)
        }
    }

}

struct ViewportState: Equatable {
    var scale: Double? = nil // nil means fit; 1 means one image pixel per display pixel
    var offset: CGSize = .zero
    var fitMultiplier: Double = 1
    mutating func zoom(by factor: Double) {
        if let scale { self.scale = min(8, max(0.05, scale * factor)) }
        else { fitMultiplier = min(32, max(0.1, fitMultiplier * factor)) }
    }
}


enum FilmstripSize: String, CaseIterable {
    case small, medium, large
    var title: String {
        switch self { case .small: "Маленькие"; case .medium: "Средние"; case .large: "Крупные" }
    }
    var width: Double {
        switch self { case .small: 70; case .medium: 100; case .large: 160 }
    }
    var imageHeight: Double { width * 0.7 }
    var stripHeight: Double { imageHeight + 48 }
}

/// A directory's rows and navigation highlight are independent of photo selection.
/// In particular, focusing a source column must survive opening its child folder.
struct BrowserColumn: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
    var entries: [CatalogEntry] = []
    var highlightedID: String?
    var loading = false
    var error: String?
    var request: UUID?
}

extension BrowserModel {
    var visibleColumns: [BrowserColumn] {
        if !columns.isEmpty, !isLibrary { return columns }
        return [BrowserColumn(url: folder ?? URL(fileURLWithPath: "/"), entries: entries,
                              highlightedID: selection.id, loading: loading, error: error)]
    }
    func columnSelection(_ column: BrowserColumn) -> Set<String> {
        if (column.url.path == folder?.path || columns.isEmpty), !selection.ids.isEmpty { return selection.ids }
        return column.highlightedID.map { [$0] } ?? []
    }
    func prepareColumns() {
        guard mode == .columns, !isLibrary, folder != nil else { return }
        if columns.last?.url.path != folder?.path { rebuildColumns() }
    }
    private func cancelColumnTasks() {
        columnTasks.values.forEach { $0.cancel() }; columnTasks = [:]
    }
    private func rebuildColumns() {
        selectFirstOnRefresh = false
        cancelColumnTasks(); folderRevision += 1
        columns = ancestors.map { BrowserColumn(url: $0) }
        guard !columns.isEmpty else { return }
        for index in columns.indices.dropLast() { columns[index].highlightedID = columns[index + 1].url.path }
        let last = columns.count - 1
        columns[last].entries = entries
        columns[last].highlightedID = selection.id
        activeColumnID = columns[last].id
        for column in columns { loadColumn(column.id) }
    }
    /// FileManager can return canonical child paths for a directory opened via
    /// an alias such as /var. Keep every immediate resource in its source
    /// directory's spelling, so row IDs and branch IDs use the same identity.
    nonisolated private static func directoryContents(_ source: any CatalogSource, of folder: URL) throws -> [CatalogEntry] {
        try source.contents(of: folder).map { entry in
            let url = folder.appendingPathComponent(entry.url.lastPathComponent)
            let asset = entry.asset.map { asset in
                PhotoAsset(resources: asset.resources.map {
                    PhotoResource(url: folder.appendingPathComponent($0.url.lastPathComponent), size: $0.size, modified: $0.modified)
                })
            }
            return CatalogEntry(url: url, asset: asset)
        }
    }
    private func loadColumn(_ id: String, nearest: Int? = nil) {
        guard !interactionLocked, let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columnTasks[id]?.cancel()
        let request = UUID(), url = columns[index].url, source = catalog
        columns[index].request = request; columns[index].loading = true; columns[index].error = nil
        if url.path == folder?.path { loading = true; error = nil }
        columnTasks[id] = Task { [weak self] in
            let result = await Task.detached { Result { try Self.directoryContents(source, of: url) } }.value
            guard !Task.isCancelled, let self, !interactionLocked,
                  let index = columns.firstIndex(where: { $0.id == id && $0.request == request }) else { return }
            columns[index].loading = false
            switch result {
            case .success(let contents):
                await loadEdits(for: contents, location: .folder(url), valid: { self.editor == nil && self.columns.contains { $0.id == id && $0.request == request } })
                guard editor == nil, columns.indices.contains(index), columns[index].request == request else { return }
                let priorEntries = columns[index].entries
                columns[index].entries = FolderCatalog.sorted(contents, by: sort, ascending: ascending)
                if let highlighted = columns[index].highlightedID,
                   !contents.contains(where: { $0.id == highlighted }) { columns[index].highlightedID = nil }
                // A refresh can remove a folder that used to lead to the active branch.
                if index + 1 < columns.count,
                   priorEntries.contains(where: { $0.isFolder && $0.id == columns[index + 1].id }),
                   !contents.contains(where: { $0.isFolder && $0.id == columns[index + 1].id }) {
                    closeColumns(after: index); setColumnLocation(url)
                    entries = columns[index].entries; select(nil); activeColumnID = id; columnFocusRevision += 1
                }
            case .failure(let failure):
                columns[index].entries = []
                columns[index].error = "Папка недоступна. \(failure.localizedDescription)"
            }
            if url.path == folder?.path {
                entries = columns[index].entries; loading = false; error = nil
                if columns[index].error != nil { select(nil) }
                else if !busy { reconcileSelection(nearest: nearest); loadPreview() }
                columns[index].highlightedID = selection.id ?? columns[index].highlightedID
            }
            columnTasks[id] = nil
        }
    }
    private func closeColumns(after index: Int) {
        for column in columns.dropFirst(index + 1) { columnTasks.removeValue(forKey: column.id)?.cancel() }
        columns = Array(columns.prefix(index + 1))
        folderRevision += 1
    }
    private func setColumnLocation(_ url: URL, recordHistory: Bool = true) {
        let destination = Location.folder(url)
        if recordHistory, folder?.path != url.path || isLibrary {
            history = Array(history.prefix(historyIndex + 1)); history.append(destination); historyIndex = history.count - 1
        }
        location = destination; catalogIssues = []; error = nil
    }
    private func useColumn(_ index: Int, recordHistory: Bool = true) {
        guard index < columns.count else { return }
        let column = columns[index]
        if folder?.path != column.url.path {
            select(nil); setColumnLocation(column.url, recordHistory: recordHistory)
            entries = column.entries; loading = column.loading
        }
        closeColumns(after: index)
    }
    func selectAllColumnPhotos(_ id: String) {
        guard !interactionLocked else { return }
        if let index = columns.firstIndex(where: { $0.id == id }) {
            useColumn(index); selectAllPhotos(); columns[index].highlightedID = selection.id
        } else { selectAllPhotos() }
    }
    func focusColumn(_ id: String) {
        guard !interactionLocked, visibleColumns.contains(where: { $0.id == id }) else { return }
        activeColumnID = id
    }
    func clickColumn(_ id: String, entryID: String?, command: Bool = false, shift: Bool = false,
                     doubleClick: Bool = false, restoring group: Set<String>? = nil) {
        guard !interactionLocked else { return }
        guard let index = columns.firstIndex(where: { $0.id == id }), !isLibrary else {
            // The managed library is a single flat catalog, with the same row behavior.
            if doubleClick, let entry = entries.first(where: { $0.id == entryID }), !entry.isFolder {
                if let group { setSelectedIDs(group, primary: entry.id) }
                else if !selection.ids.contains(entry.id) { select(entry.id) }
                activate(entry)
            } else { selectGesture(entryID, command: command, shift: shift) }
            return
        }
        activeColumnID = id
        guard let entryID, let entry = columns[index].entries.first(where: { $0.id == entryID }) else {
            useColumn(index); columns[index].highlightedID = nil; select(nil); return
        }
        if entry.isFolder {
            // The second down of a double click must not repeat an already opened branch.
            if columns[index].highlightedID == entryID, index + 1 < columns.count,
               columns[index + 1].id == entry.id {
                guard !doubleClick else { return }
                let child = columns[index + 1]
                closeColumns(after: index + 1); setColumnLocation(child.url)
                entries = child.entries; loading = child.loading
                columns[index + 1].highlightedID = nil
                select(nil); loadPreview(); return
            }
            useColumn(index, recordHistory: false); columns[index].highlightedID = entryID
            select(nil); loadPreview()
            setColumnLocation(entry.url); entries = []; loading = true
            columns.append(BrowserColumn(url: entry.url))
            loadColumn(entry.url.path)
        } else {
            useColumn(index)
            columns[index].highlightedID = entryID
            if doubleClick {
                if let group { setSelectedIDs(group, primary: entryID) }
                else if !selection.ids.contains(entryID) { select(entryID) }
                activate(entry); return
            } else { selectGesture(entryID, command: command, shift: shift) }
            columns[index].highlightedID = selection.id
        }
    }
    /// Return false for keys belonging to text, system commands or another view.
    @discardableResult func columnKey(_ code: UInt16, shift: Bool = false) -> Bool {
        guard !interactionLocked, mode == .columns else { return false }
        let visible = visibleColumns
        guard let id = activeColumnID ?? visible.last?.id,
              let index = visible.firstIndex(where: { $0.id == id }) else { return false }
        let column = visible[index]
        switch code {
        case 125, 126:
            guard !column.entries.isEmpty else { return true }
            let selectedID = columnSelection(column).contains(selection.id ?? "") ? selection.id : column.highlightedID
            let delta = code == 125 ? 1 : -1
            let old = column.entries.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : column.entries.count)
            let target = column.entries[min(max(old + delta, 0), column.entries.count - 1)]
            clickColumn(id, entryID: target.id, shift: shift)
        case 124:
            guard !shift else { return false }
            if let target = column.entries.first(where: { $0.id == column.highlightedID && $0.isFolder }) {
                clickColumn(id, entryID: target.id)
                if index + 1 < columns.count {
                    activeColumnID = columns[index + 1].id; columnFocusRevision += 1
                }
            }
        case 123:
            guard !shift else { return false }
            guard index > 0, !columns.isEmpty else { return true }
            let exited = columns[index].url.path
            useColumn(index - 1); select(nil); loadPreview()
            columns[index - 1].highlightedID = exited
            activeColumnID = columns[index - 1].id; columnFocusRevision += 1
        default: return false
        }
        return true
    }
}

extension BrowserModel {
    var canCompare: Bool { comparison == nil && selectedAssets.count == 2 && !interactionLocked && !loading }
    func startComparison() {
        guard canCompare else { return }
        let assets = selectedAssets
        let primary = selection.id
        if mode != .gallery { priorMode = mode; mode = .gallery }
        previewTask?.cancel(); prefetchTask?.cancel()
        preview = nil; previewError = nil; previewLoading = false
        let recipeByURL = Dictionary(uniqueKeysWithValues: photos.compactMap(\.asset).flatMap { asset in asset.resources.map { ($0.url, edits[asset.id] ?? .identity) } })
        comparison = ComparisonSession(assets: assets, primary: primary, recipes: recipeByURL)
        syncComparisonSelection()
    }
    func syncComparisonSelection() {
        guard let comparison else { return }
        selection.replace(Set(comparison.panes.map { $0.asset.id }), primary: comparison.activePane.asset.id, orderedIDs: photos.map(\.id))
    }
    func activateComparisonPane(_ index: Int) {
        guard !interactionLocked, let comparison, comparison.panes.indices.contains(index) else { return }
        comparison.active = index; syncComparisonSelection()
    }
    func exitComparison() {
        guard !interactionLocked else { return }
        endComparison()
    }
    private func endComparison() {
        guard let session = comparison else { return }
        session.cancel(); comparison = nil
        viewport = session.viewport
        selection.replace(Set(session.panes.map { $0.asset.id }), primary: session.activePane.asset.id, orderedIDs: photos.map(\.id))
        if selection.showsRAW != session.activePane.showsRAW { selection.toggleRAW() }
        loadPreview()
    }
    func replaceComparison(with id: String) {
        guard !interactionLocked, let session = comparison, let asset = photos.first(where: { $0.id == id })?.asset else { return }
        if let index = session.panes.firstIndex(where: { $0.asset.id == id }) { activateComparisonPane(index); return }
        session.replace(session.active, with: asset); syncComparisonSelection()
    }
    func stepComparison(_ delta: Int) {
        guard !interactionLocked, let session = comparison, let current = photos.firstIndex(where: { $0.id == session.activePane.asset.id }) else { return }
        var index = current + delta
        while photos.indices.contains(index) {
            if photos[index].id != session.panes[1 - session.active].asset.id { replaceComparison(with: photos[index].id); return }
            index += delta
        }
    }
    func completeComparisonTrash(snapshot: ComparisonTrashSnapshot, succeeded: Bool) {
        let session = snapshot.session
        guard succeeded, comparison === session else { return }
        let slot = snapshot.slot
        // Never apply a completion to a replacement that no longer represents the confirmed asset.
        guard session.panes[slot].asset == snapshot.asset else { return }
        let other = session.panes[1 - slot].asset.id
        let index = snapshot.photoIDs.firstIndex(of: snapshot.asset.id) ?? 0
        let candidates = Array(snapshot.photoIDs.dropFirst(index + 1)) + Array(snapshot.photoIDs.prefix(index).reversed())
        if let replacement = candidates.first(where: { candidate in candidate != other && photos.contains { $0.id == candidate } }),
           let asset = entries.first(where: { $0.id == replacement })?.asset {
            session.replace(slot, with: asset); syncComparisonSelection()
        } else {
            session.active = 1 - slot; endComparison()
            selection.select(other)
        }
    }
    func reconcileComparison() {
        guard let session = comparison else { return }
        session.setRecipes(Dictionary(uniqueKeysWithValues: photos.compactMap(\.asset).flatMap { asset in asset.resources.map { ($0.url, edits[asset.id] ?? .identity) } }))
        for index in session.panes.indices {
            let prior = session.panes[index].asset
            // A partially trashed pair may now be identified by its remaining RAF.
            let urls = Set(prior.resources.map(\.url))
            guard let asset = photos.compactMap(\.asset).first(where: { $0.id == prior.id || $0.resources.contains { urls.contains($0.url) } }) else {
                let survivorIndex = 1 - index
                let survivorURLs = Set(session.panes[survivorIndex].asset.resources.map(\.url))
                let survivor = photos.compactMap(\.asset).first { asset in
                    asset.resources.contains { survivorURLs.contains($0.url) }
                }
                if let survivor { session.update(survivorIndex, asset: survivor) }
                session.active = survivorIndex; endComparison()
                if let survivor { selection.select(survivor.id) }
                else { selection.retain(orderedIDs: photos.map(\.id)) }
                return
            }
            session.update(index, asset: asset)
        }
        syncComparisonSelection()
    }
    func zoom(by factor: Double) {
        guard !interactionLocked else { return }
        if let comparison { comparison.zoom(by: factor) } else { viewport.zoom(by: factor) }
    }
    func fitPreview() { guard !interactionLocked else { return }; if let comparison { comparison.viewport = ViewportState() } else { viewport = ViewportState() } }
    func actualSize() { guard !interactionLocked else { return }; if let comparison { comparison.viewport = ViewportState(scale: 1) } else { viewport = ViewportState(scale: 1) } }
}

/// Value snapshot binds a confirmed trash action to its original slot and complete asset.
@MainActor struct ComparisonTrashSnapshot {
    let session: ComparisonSession
    let slot: Int
    let asset: PhotoAsset
    let photoIDs: [String]
    init(session: ComparisonSession, slot: Int? = nil, photoIDs: [String]) {
        self.session = session
        self.slot = slot ?? session.active
        self.asset = session.panes[self.slot].asset
        self.photoIDs = photoIDs
    }
}
