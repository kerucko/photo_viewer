import AppKit
import SwiftUI
import PhotoCore

@MainActor @Observable final class BrowserModel {
    enum Location: Equatable {
        case folder(URL), library(URL)
        var url: URL { switch self { case .folder(let url), .library(let url): url } }
    }
    private(set) var location: Location?
    var folder: URL? { location?.url }
    var isLibrary: Bool { if case .library = location { true } else { false } }
    var libraryRoot: URL? = UserDefaults.standard.url(forKey: "libraryRoot")
    private var library: PhotoLibrary?
    var busy = false
    var operationTitle = ""
    var selectedAssets: [PhotoAsset] { entries.filter { selection.ids.contains($0.id) }.compactMap(\.asset) }
    var canTrash: Bool { !selectedAssets.isEmpty && !busy && !loading }
    var canSelectAll: Bool { mode != .gallery && !photos.isEmpty && !busy }
    var canUp: Bool { !busy && !isLibrary && folder != nil && folder?.path != "/" }
    var entries: [CatalogEntry] = []
    var selection = SelectionState()
    var loading = false
    var error: String?
    var catalogIssues: [String] = []
    var preview: RenderedImage?
    var previewError: String?
    var previewLoading = false
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
    private let catalog: any CatalogSource = FolderCatalog()
    init() { selection.mode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .icons }
    var selected: CatalogEntry? { entries.first { $0.id == selection.id } }
    var selectedResource: PhotoResource? {
        guard let asset = selected?.asset else { return nil }
        return selection.showsRAW ? (asset.raw ?? asset.preferred) : asset.preferred
    }
    var canZoom: Bool { preview != nil && (mode == .gallery || mode == .columns) }
    var photos: [CatalogEntry] { entries.filter { !$0.isFolder } }
    var mode: ViewMode {
        get { selection.mode }
        set { selection.mode = newValue; UserDefaults.standard.set(newValue.rawValue, forKey: "mode") }
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
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Открыть"; panel.message = "Выберите папку с фотографиями"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, recordHistory: Bool = true) {
        navigate(.folder(url), recordHistory: recordHistory)
    }
    private func navigate(_ destination: Location, recordHistory: Bool = true) {
        guard !busy else { return }
        if recordHistory && location != destination {
            history = Array(history.prefix(historyIndex + 1)); history.append(destination); historyIndex = history.count - 1
        }
        let changed = location != destination
        location = destination
        if case .library(let root) = destination {
            if library?.root != root { library = PhotoLibrary(root: root) }
        }
        if changed { entries = []; catalogIssues = []; select(nil); selectFirstOnRefresh = true }
        reload()
    }
    func back() { guard !busy, canBack else { return }; historyIndex -= 1; navigate(history[historyIndex], recordHistory: false) }
    func forward() { guard !busy, canForward else { return }; historyIndex += 1; navigate(history[historyIndex], recordHistory: false) }
    func up() { guard canUp, let folder else { return }; open(folder.deletingLastPathComponent()) }
    func reload() {
        guard !busy else { return }
        Task { await refresh() }
    }
    private func refresh(nearest index: Int? = nil) async {
        guard let location else { return }
        folderRevision += 1; let revision = folderRevision
        loading = true; error = nil
        let source = catalog
        do {
            let contents: [CatalogEntry]
            var issues: [String] = []
            switch location {
            case .folder(let folder): contents = try await Task.detached { try source.contents(of: folder) }.value
            case .library(let root):
                if library?.root != root { library = PhotoLibrary(root: root) }
                let snapshot = try await library!.snapshot()
                contents = snapshot.entries; issues = snapshot.issues
            }
            guard revision == folderRevision else { return }
            catalogIssues = issues
            entries = FolderCatalog.sorted(contents, by: sort, ascending: ascending)
            loading = false
            reconcileSelection(nearest: index, selectFirstIfEmpty: selectFirstOnRefresh)
            selectFirstOnRefresh = false
            loadPreview()
        } catch {
            guard revision == folderRevision else { return }
            entries = []; catalogIssues = []; select(nil); loading = false
            self.error = "Папка недоступна. Проверьте подключение носителя и права доступа.\n\(error.localizedDescription)"
        }
    }
    @discardableResult func chooseLibrary() -> Bool {
        guard !busy else { return false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Выбрать библиотеку"
        panel.message = "Выберите или создайте папку для библиотеки. Здесь будут храниться копии фотографий, независимо от SD-карты."
        guard panel.runModal() == .OK, let root = panel.url else { return false }
        libraryRoot = root; UserDefaults.standard.set(root, forKey: "libraryRoot")
        navigate(.library(root)); return true
    }
    func openLibrary() {
        guard !busy else { return }
        if let libraryRoot { navigate(.library(libraryRoot)) } else { chooseLibrary() }
    }
    func chooseImport() {
        guard !busy else { return }
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
                busy = false; loadPreview()
                if location == .library(root) { await refresh() }
                let alert = NSAlert()
                alert.messageText = "Импорт завершён"
                alert.informativeText = "Добавлено файлов: \(report.imported). Пропущено: \(report.skipped)." + (report.issues.isEmpty ? "" : "\n\n" + Self.summarizeIssues(report.issues))
                alert.addButton(withTitle: "Открыть библиотеку").toolTip = "Открыть библиотеку с импортированными фотографиями"
                alert.addButton(withTitle: "Закрыть").toolTip = "Закрыть отчёт об импорте"
                if alert.runModal() == .alertFirstButtonReturn { navigate(.library(root)) }
            } catch {
                busy = false; loadPreview()
                showMessage("Не удалось импортировать", error.localizedDescription)
                if location == .library(root) { await refresh() }
            }
        }
    }
    func confirmTrash() {
        guard canTrash, location != nil else { return }
        // Capture the complete group before confirmation or asynchronous work.
        let assets = selectedAssets
        let alert = Self.trashConfirmation(for: assets)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = photos.firstIndex { $0.id == selection.id } ?? 0
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
            busy = false
            await refresh(nearest: index)
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
        previewTask?.cancel(); prefetchTask?.cancel()
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
        guard !busy else { return }
        if sort == field { ascending.toggle() } else { sort = field; ascending = true }
        UserDefaults.standard.set(sort.rawValue, forKey: "sort"); UserDefaults.standard.set(ascending, forKey: "ascending")
        entries = FolderCatalog.sorted(entries, by: sort, ascending: ascending)
    }
    private func changeSelection(_ change: (inout SelectionState) -> Void) {
        guard !busy else { return }
        let prior = selection.id
        change(&selection)
        if prior != selection.id { viewport = ViewportState(); loadPreview() }
    }
    func select(_ id: String?) {
        guard !busy else { return }
        selectFirstOnRefresh = false
        changeSelection { $0.select(id) }
    }
    func selectGesture(_ id: String?, command: Bool = false, shift: Bool = false) {
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
        let hadSelection = !selection.ids.isEmpty
        let prior = selection.id
        selection.retain(orderedIDs: entries.map(\.id))
        if (hadSelection || selectFirstIfEmpty), selection.ids.isEmpty, !photos.isEmpty {
            selection.select(photos[min(index ?? 0, photos.count - 1)].id)
        }
        if prior != selection.id { viewport = ViewportState() }
    }
    func activate(_ entry: CatalogEntry) {
        guard !busy else { return }
        if entry.isFolder { open(entry.url) }
        else {
            changeSelection { $0.focus(entry.id) }
            if mode != .gallery { priorMode = mode }
            mode = .gallery
        }
    }
    func toggleGallery() {
        guard !busy else { return }
        if mode == .gallery { mode = priorMode }
        else if selected?.asset != nil { priorMode = mode; mode = .gallery }
    }
    func step(_ delta: Int) {
        guard !photos.isEmpty else { return }
        let current = photos.firstIndex { $0.id == selection.id } ?? (delta > 0 ? -1 : photos.count)
        select(photos[min(max(current + delta, 0), photos.count - 1)].id)
    }
    func extendSelection(by delta: Int) {
        guard !busy, !photos.isEmpty else { return }
        let current = photos.firstIndex { $0.id == selection.id } ?? (delta > 0 ? -1 : photos.count)
        selectGesture(photos[min(max(current + delta, 0), photos.count - 1)].id, shift: true)
    }
    func toggleRAW() {
        guard !busy else { return }
        guard selected?.asset?.isPair == true else { return }
        selection.toggleRAW(); viewport = ViewportState(); loadPreview()
    }
    private func loadPreview() {
        previewTask?.cancel(); prefetchTask?.cancel(); preview = nil; previewError = nil; previewLoading = false
        guard let asset = selected?.asset else { return }
        let resource = selection.showsRAW ? (asset.raw ?? asset.preferred) : asset.preferred
        let revision = selection.revision
        previewLoading = true
        previewTask = Task {
            do {
                let image = try await ImageService.shared.image(resource, maxPixel: nil)
                guard !Task.isCancelled, selection.accepts(revision) else { return }
                preview = image; previewLoading = false
            } catch {
                guard !Task.isCancelled, selection.accepts(revision) else { return }
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
