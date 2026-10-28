import SwiftUI
import AppKit
import PhotoCore

@main struct PhotoViewerApp: App {
    @NSApplicationDelegateAdaptor(PhotoViewerLifecycle.self) private var lifecycle
    @State private var model = BrowserModel()
    var body: some Scene {
        Window("Фото", id: "main") {
            BrowserView(model: model)
                .frame(minWidth: 850, minHeight: 560)
                .onAppear { PhotoViewerLifecycle.model = model }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandMenu("Вид") {
                Button("Редактировать") { model.startEditing() }.keyboardShortcut("e", modifiers: .command).disabled(!model.canEdit)
                Menu("Сетка") {
                    Picker("Сетка", selection: $model.grid) { ForEach(PhotoGrid.allCases, id: \.self) { Text($0.title).tag($0) } }
                }
                Divider()
                Button("Сравнить выбранные") { model.startComparison() }.disabled(!model.canCompare)
                Divider()
                Button("Увеличить") { model.zoom(by: 1.4) }
                    .keyboardShortcut("=", modifiers: .command).disabled(!model.canZoom)
                Button("Уменьшить") { model.zoom(by: 1 / 1.4) }
                    .keyboardShortcut("-", modifiers: .command).disabled(!model.canZoom)
                Button("Вписать в окно") { model.fitPreview() }
                    .keyboardShortcut("0", modifiers: .command).disabled(!model.canZoom)
                Button("Реальный размер (100%)") { model.actualSize() }
                    .keyboardShortcut("1", modifiers: .command).disabled(!model.canZoom)
                Divider()
                Toggle("Показать сведения", isOn: $model.showMetadata)
                    .keyboardShortcut("i", modifiers: .command).disabled(model.editor != nil)
                Menu("Размер миниатюр в галерее") {
                    Picker("Размер", selection: $model.filmstripSize) {
                        ForEach(FilmstripSize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                    }.pickerStyle(.inline)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Открыть папку…") { model.chooseFolder() }.keyboardShortcut("o").disabled(model.interactionLocked)
                Button("Открыть библиотеку…") { model.chooseLibrary() }.disabled(model.interactionLocked)
                Button("Библиотека") { model.openLibrary() }.disabled(model.interactionLocked)
                Button("Импортировать с SD…") { model.chooseImport() }.disabled(model.interactionLocked)
                Button("Создать ZIP-архив…") { model.createZIP() }.disabled(!model.canExportZIP)
                Divider()
                Button(model.comparison == nil ? "Переместить выбранные снимки в Корзину…" : "Переместить активный снимок в Корзину…") { model.confirmTrash() }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(!model.canTrash)
                Button("Обновить") { model.reload() }.keyboardShortcut("r").disabled(model.interactionLocked)
            }
        }
    }
}

/// Owns its group backgrounds and spacing so macOS cannot merge adjacent toolbar items.
struct NavigationToolbarView: View {
    @Bindable var model: BrowserModel
    var compact: Bool

    var statusText: String {
        if model.busy { return model.operationTitle }
        let selected = model.selectedAssets.count
        if selected == 0 { return "\(model.photos.count) фото" }
        return compact ? "Выбрано: \(selected)" : "\(model.photos.count) фото · выбрано \(selected)"
    }
    private var statusHelp: String {
        if model.busy { return model.operationTitle }
        return "\(model.photos.count) фото · выбрано \(model.selectedAssets.count)"
    }

    private var folderName: String {
        guard let folder = model.folder else { return "Фото" }
        return folder.lastPathComponent.isEmpty ? "/" : folder.lastPathComponent
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func navigationButton(_ symbol: String, title: String, help: String, disabled: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(title)
    }

    var body: some View {
        HStack(spacing: 12) {
            group {
                HStack(spacing: 8) {
                    navigationButton("chevron.left", title: "Назад", help: "Назад по истории", disabled: model.busy || !model.canBack, action: model.back)
                    navigationButton("chevron.right", title: "Вперёд", help: "Вперёд по истории", disabled: model.busy || !model.canForward, action: model.forward)
                    navigationButton("arrow.up", title: "На уровень выше", help: "Открыть родительскую папку", disabled: model.busy || !model.canUp, action: model.up)
                }
            }
            group {
                navigationButton("folder.badge.plus", title: "Открыть папку", help: "Открыть папку… (⌘O)", disabled: model.busy, action: model.chooseFolder)
            }
            group {
                HStack(spacing: 8) {
                    Image(systemName: model.isLibrary ? "photo.stack" : "folder")
                        .foregroundStyle(.secondary)
                    Text(folderName)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: compact ? 100 : 180, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .help(model.folder?.path ?? "Выберите папку с фотографиями")
            }
            group {
                HStack(spacing: 8) {
                    if model.loading || model.busy {
                        ProgressView().controlSize(.small)
                            .help(model.busy ? model.operationTitle : "Загрузка папки…")
                    }
                    Text(statusText)
                        .foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: compact ? 90 : 160, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(statusHelp)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: true, vertical: false)
    }
}

@MainActor enum BrowserKeyboard {
    static func handle(_ event: NSEvent, model: BrowserModel, firstResponder: NSResponder?) -> Bool {
        guard !model.interactionLocked, NSApp.modalWindow == nil, !(firstResponder is NSTextView), !(firstResponder is NSTextField) else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if model.mode == .columns {
            guard let table = firstResponder as? ColumnTableView, table.browserModel === model else { return false }
            model.focusColumn(table.columnID)
            if event.keyCode == 0, modifiers == .command {
                model.selectAllColumnPhotos(table.columnID); return true
            }
            if [123, 124, 125, 126].contains(event.keyCode), modifiers.isEmpty || modifiers == .shift {
                return model.columnKey(event.keyCode, shift: modifiers == .shift)
            }
        }
        if event.keyCode == 0, modifiers == .command, model.canSelectAll {
            model.selectAllPhotos(); return true
        }
        guard modifiers.isEmpty else { return false }
        if model.comparison != nil {
            if event.keyCode == 48 { model.activateComparisonPane(1 - model.comparison!.active); return true }
            if event.keyCode == 53 { model.exitComparison(); return true }
        }
        switch event.keyCode {
        case 123: model.step(-1); return true
        case 124: model.step(1); return true
        case 49: model.toggleGallery(); return true
        default: return false
        }
    }
}

struct BrowserView: View {
    @Bindable var model: BrowserModel
    @State private var keyMonitor: Any?
    @State private var contentWidth: CGFloat = 0
    private var compactToolbar: Bool { contentWidth < 1150 }
    private var viewModePicker: some View {
        Picker("Вид", selection: $model.mode) {
            Label("Значки", systemImage: "square.grid.2x2").tag(ViewMode.icons).help("Значки")
            Label("Список", systemImage: "list.bullet").tag(ViewMode.list).help("Список")
            Label("Колонки", systemImage: "rectangle.split.3x1").tag(ViewMode.columns).help("Колонки")
            Label("Галерея", systemImage: "rectangle.bottomthird.inset.filled").tag(ViewMode.gallery).help("Галерея")
        }
    }

    private var viewModeSymbol: String {
        switch model.mode {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        case .gallery: "rectangle.bottomthird.inset.filled"
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            NavigationToolbarView(model: model, compact: compactToolbar)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.editor == nil, let id = model.selection.id, let warning = model.editWarnings[id] {
                HStack {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.callout).lineLimit(3)
                    Spacer(minLength: 8)
                }.padding(10)
                Divider()
            }
            if !model.catalogIssues.isEmpty {
                HStack {
                    Label("Недоступные файлы: \(model.catalogIssues.count). Остальные фотографии доступны.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Подробнее…") { model.showCatalogIssues() }
                        .help("Показать сведения о недоступных файлах библиотеки")
                }.font(.callout).padding(10)
                Divider()
            }
            if let editor = model.editor {
                PhotoEditorView(model: model, session: editor)
            } else if let error = model.error, model.mode != .columns {
                ContentUnavailableView { Label("Папка недоступна", systemImage: "externaldrive.badge.exclamationmark") } description: { Text(error) } actions: { Button("Повторить") { model.reload() }.help("Повторить загрузку папки (⌘R)") }
            } else if model.folder == nil {
                ContentUnavailableView { Label("Ваши фотографии", systemImage: "photo.on.rectangle.angled") } description: { Text("Откройте папку или перетащите её сюда.\nJPG и RAF одного снимка будут показаны вместе.") } actions: { Button("Открыть папку…") { model.chooseFolder() }.buttonStyle(.borderedProminent).help("Открыть папку с фотографиями (⌘O)") }
            } else {
                switch model.mode {
                case .icons: IconGrid(model: model)
                case .list: FileTable(model: model)
                case .columns: ColumnBrowser(model: model)
                case .gallery: GalleryView(model: model)
                }
                if model.entries.isEmpty && !model.loading {
                    Text("В папке нет JPG, RAF или вложенных папок").foregroundStyle(.secondary).padding()
                }
            }
            if model.mode != .gallery, model.editor == nil {
                Divider()
                HStack {
                    Text(model.selected?.name ?? "Нет выделения").lineLimit(1)
                    Spacer()
                    if model.selected?.asset?.isPair == true {
                        Button(model.showsRAW ? "RAW → JPG" : "JPG → RAW") { model.toggleRAW() }
                            .help(model.showsRAW ? "Показать JPEG" : "Показать проявленный RAW")
                    } else if let asset = model.selected?.asset { Text(asset.kind).foregroundStyle(.secondary) }
                }.font(.callout).padding(10)
            }
        }
        .disabled(model.busy)
        .background(EditorWindowGuard(model: model).frame(width: 0, height: 0))
        .inspector(isPresented: Binding(get: { model.showMetadata && model.editor == nil }, set: { if model.editor == nil { model.showMetadata = $0 } })) {
            MetadataSidebar(entry: model.selected, resource: model.selectedResource, resultingSize: model.resultingSize)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .sheet(item: $model.zipSession) { ZIPExportView(session: $0) }
        .navigationTitle("")
        .toolbar {
            if model.editor == nil {
            navigationToolbar
            if model.mode != .gallery {
                ToolbarItem {
                    Button("Создать ZIP-архив…", systemImage: "archivebox") { model.createZIP() }
                        .disabled(!model.canExportZIP).help("Создать ZIP-архив выбранных снимков или всей папки")
                }
                ToolbarSpacer(.fixed)
            }
            if model.mode != .gallery {
                ToolbarItem {
                    if model.comparison != nil {
                        Button("Завершить сравнение", systemImage: "xmark.rectangle") { model.exitComparison() }
                            .disabled(model.interactionLocked).help("Вернуться к активному снимку в галерее (Esc)")
                    } else {
                        Button("Сравнить выбранные", systemImage: "rectangle.split.2x1") { model.startComparison() }
                            .disabled(!model.canCompare).help("Сравнить два выбранных снимка")
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                if compactToolbar {
                    Menu {
                        viewModePicker
                    } label: {
                        Label("Вид", systemImage: viewModeSymbol)
                    }.disabled(model.interactionLocked).help("Выбрать режим просмотра")
                } else {
                    viewModePicker.pickerStyle(.segmented).frame(width: 180).disabled(model.interactionLocked)
                }
            }
            if model.mode == .gallery {
                ToolbarItem {
                    GalleryActionsToolbarView(model: model)
                }.sharedBackgroundVisibility(.hidden)
                if compactToolbar {
                    ToolbarItem {
                        Menu {
                            Button("Вписать в окно") { model.fitPreview() }
                            Button("Реальный размер (100%)") { model.actualSize() }
                            Divider()
                            Button("Уменьшить") { model.zoom(by: 1 / 1.4) }
                            Button("Увеличить") { model.zoom(by: 1.4) }
                        } label: {
                            Label("Масштаб", systemImage: "magnifyingglass")
                        }
                        .disabled(model.busy || !model.canZoom)
                        .help("Масштаб: вписать, 100%, уменьшить или увеличить")
                    }
                } else {
                    ToolbarItemGroup {
                        Button("Вписать") { model.fitPreview() }
                            .disabled(model.busy || !model.canZoom)
                            .help("Вписать в окно (⌘0)")
                        Button("100%") { model.actualSize() }
                            .disabled(model.busy || !model.canZoom)
                            .help("Реальный размер — 100% (⌘1)")
                        Button { model.zoom(by: 1 / 1.4) } label: {
                            Label("Уменьшить", systemImage: "minus.magnifyingglass")
                        }.disabled(model.busy || !model.canZoom).help("Уменьшить (⌘−)")
                        Button { model.zoom(by: 1.4) } label: {
                            Label("Увеличить", systemImage: "plus.magnifyingglass")
                        }.disabled(model.busy || !model.canZoom).help("Увеличить (⌘=)")
                    }
                }
            }
            if model.mode == .icons {
                ToolbarItem {
                    Slider(value: $model.iconSize, in: 100...240).frame(width: 100).disabled(model.interactionLocked).help("Размер значков")
                }
            }
            ToolbarItem {
                Menu {
                    Button("Имя") { model.setSort(.name) }
                    Button("Тип") { model.setSort(.kind) }
                    Button("Дата изменения") { model.setSort(.modified) }
                    Button("Размер") { model.setSort(.size) }
                } label: { Label("Сортировка", systemImage: "arrow.up.arrow.down") }
                .disabled(model.interactionLocked)
                .help("Выбрать порядок сортировки")
            }
            ToolbarItem {
                Button(action: model.confirmTrash) { Label(model.comparison == nil ? "В Корзину" : "Активный снимок в Корзину", systemImage: "trash") }
                    .disabled(model.busy || !model.canTrash).help(model.comparison == nil ? "Переместить все файлы выбранных снимков в Корзину (⌘⌫)" : "Переместить все файлы только активного снимка в Корзину (⌘⌫)")
            }
            ToolbarItem {
                Button(action: model.reload) { Label("Обновить", systemImage: "arrow.clockwise") }.disabled(model.interactionLocked).help("Обновить (⌘R)")
            }
            ToolbarItemGroup {
                Button("Редактировать", systemImage: "crop.rotate") { model.startEditing() }.disabled(!model.canEdit).help("Кадрировать и повернуть снимок (⌘E)")
                Button { model.showMetadata.toggle() } label: { Label("Сведения", systemImage: "sidebar.right") }
                    .disabled(model.interactionLocked).help(model.showMetadata ? "Скрыть сведения (⌘I)" : "Показать сведения (⌘I)")
            }
            } else {
                ToolbarItem(placement: .principal) {
                    Text(model.editor?.asset.name ?? "Редактирование").font(.headline).lineLimit(1)
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(.regularMaterial, in: Capsule())
                }.sharedBackgroundVisibility(.hidden)
            }
        }

        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !model.interactionLocked, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
                Task { @MainActor in model.open(url) }
            }
            return true
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let window = NSApp.keyWindow, NSApp.modalWindow == nil else { return event }
                return BrowserKeyboard.handle(event, model: model, firstResponder: window.firstResponder) ? nil : event
            }
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    }
}

struct Thumbnail: View {
    let asset: PhotoAsset
    var edit: PhotoEdit = .identity
    private struct Request: Equatable { let asset: PhotoAsset; let edit: PhotoEdit }
    @State private var image: RenderedImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4))
            if let image { Image(decorative: image.cgImage, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: failed ? "exclamationmark.triangle" : "photo").foregroundStyle(.secondary) }
        }
        .task(id: Request(asset: asset, edit: edit)) {
            image = nil; failed = false
            do { let result = try await ImageService.shared.image(asset.preferred, maxPixel: 480, edit: edit); if !Task.isCancelled { image = result } }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

/// Own the gap and inset so macOS cannot merge away spacing between these actions.
struct GalleryActionsToolbarView: View {
    @Bindable var model: BrowserModel
    var body: some View {
        HStack(spacing: 12) {
            if model.comparison != nil {
                Button("Завершить сравнение", systemImage: "xmark.rectangle") { model.exitComparison() }
                    .labelStyle(.iconOnly)
                    .disabled(model.interactionLocked).help("Вернуться к активному снимку в галерее (Esc)")
            } else {
                Button("Сравнить выбранные", systemImage: "rectangle.split.2x1") { model.startComparison() }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canCompare).help("Сравнить два выбранных снимка")
            }
            if model.selected?.asset?.isPair == true {
                Button(model.showsRAW ? "RAW → JPG" : "JPG → RAW") { model.toggleRAW() }
                    .disabled(model.interactionLocked).help(model.showsRAW ? "Показать JPEG" : "Показать проявленный RAW")
            } else if let asset = model.selected?.asset {
                Text(asset.kind).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.regularMaterial, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct GalleryView: View {
    @Bindable var model: BrowserModel
    var body: some View {
        VStack(spacing: 0) {
            if let session = model.comparison { ComparisonView(model: model, session: session) }
            else { PreviewPane(model: model) }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(model.comparison == nil ? model.entries : model.photos) { entry in
                            VStack(spacing: 4) {
                                if let asset = entry.asset { Thumbnail(asset: asset, edit: model.edit(for: asset)).frame(width: model.filmstripSize.width, height: model.filmstripSize.imageHeight) }
                                else { Image(systemName: "folder.fill").font(.largeTitle).frame(width: model.filmstripSize.width, height: model.filmstripSize.imageHeight) }
                                Text(entry.name).font(.caption).lineLimit(1).frame(width: model.filmstripSize.width)
                            }.padding(5).background(model.selection.ids.contains(entry.id) ? Color.accentColor.opacity(model.selection.id == entry.id ? 0.35 : 0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .id(entry.id)
                                .overlay { GalleryThumbnailClickTarget(model: model, entryID: entry.id) }
                        }
                    }.padding(10)
                }.frame(height: model.filmstripSize.stripHeight)
                    .onChange(of: SelectionScrollRequest(model), initial: true) { _, request in
                        if let id = request.id, request.entries.contains(id) { proxy.scrollTo(id, anchor: .center) }
                    }
            }.id(model.filmstripSize)
        }
    }
}

struct PreviewPane: View {
    @Bindable var model: BrowserModel
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = model.preview { ZoomCanvas(image: image.cgImage, state: $model.viewport, grid: model.grid) }
            else if model.previewLoading { ProgressView("Загрузка изображения…") }
            else if let error = model.previewError { ContentUnavailableView("Не удалось открыть фото", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ContentUnavailableView("Выберите фотографию", systemImage: "photo") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
}
