import AppKit
import SwiftUI
import PhotoCore

@MainActor @Observable final class BrowserModel {
    var folder: URL?
    var entries: [CatalogEntry] = []
    var selection = SelectionState()
    var loading = false
    var error: String?
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
    private var history: [URL] = []
    private var historyIndex = -1
    private var folderRevision = 0
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
        guard var url = folder else { return [] }
        var result = [url]
        while url.path != "/" { url.deleteLastPathComponent(); result.insert(url, at: 0) }
        return result
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Открыть"; panel.message = "Выберите папку с фотографиями"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, recordHistory: Bool = true) {
        if recordHistory && folder != url {
            history = Array(history.prefix(historyIndex + 1)); history.append(url); historyIndex = history.count - 1
        }
        let changed = folder != url
        folder = url
        if changed { entries = []; select(nil) }
        reload()
    }
    func back() { guard canBack else { return }; historyIndex -= 1; open(history[historyIndex], recordHistory: false) }
    func forward() { guard canForward else { return }; historyIndex += 1; open(history[historyIndex], recordHistory: false) }
    func up() { guard let folder, folder.path != "/" else { return }; open(folder.deletingLastPathComponent()) }
    func reload() {
        guard let folder else { return }
        folderRevision += 1; let revision = folderRevision
        loading = true; error = nil
        let source = catalog
        Task {
            do {
                let contents = try await Task.detached { try source.contents(of: folder) }.value
                guard revision == folderRevision else { return }
                entries = FolderCatalog.sorted(contents, by: sort, ascending: ascending)
                loading = false
                if !entries.contains(where: { $0.id == selection.id }) { select(photos.first?.id) }
                else { loadPreview() }
            } catch {
                guard revision == folderRevision else { return }
                entries = []; select(nil); loading = false
                self.error = "Папка недоступна. Проверьте подключение носителя и права доступа.\n\(error.localizedDescription)"
            }
        }
    }
    func setSort(_ field: CatalogSort) {
        if sort == field { ascending.toggle() } else { sort = field; ascending = true }
        UserDefaults.standard.set(sort.rawValue, forKey: "sort"); UserDefaults.standard.set(ascending, forKey: "ascending")
        entries = FolderCatalog.sorted(entries, by: sort, ascending: ascending)
    }
    func select(_ id: String?) {
        guard selection.id != id else { return }
        selection.select(id); viewport = ViewportState(); loadPreview()
    }
    func activate(_ entry: CatalogEntry) {
        if entry.isFolder { open(entry.url) } else { select(entry.id); if mode != .gallery { priorMode = mode }; mode = .gallery }
    }
    func toggleGallery() {
        if mode == .gallery { mode = priorMode }
        else if selected?.asset != nil { priorMode = mode; mode = .gallery }
    }
    func step(_ delta: Int) {
        guard !photos.isEmpty else { return }
        let current = photos.firstIndex { $0.id == selection.id } ?? (delta > 0 ? -1 : photos.count)
        select(photos[min(max(current + delta, 0), photos.count - 1)].id)
    }
    func toggleRAW() {
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
