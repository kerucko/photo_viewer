import SwiftUI
import AppKit
import PhotoCore

@main struct PhotoViewerApp: App {
    @State private var model = BrowserModel()
    var body: some Scene {
        Window("Фото", id: "main") {
            BrowserView(model: model)
                .frame(minWidth: 850, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandMenu("Вид") {
                Button("Увеличить") { model.viewport.zoom(by: 1.4) }
                    .keyboardShortcut("=", modifiers: .command).disabled(!model.canZoom)
                Button("Уменьшить") { model.viewport.zoom(by: 1 / 1.4) }
                    .keyboardShortcut("-", modifiers: .command).disabled(!model.canZoom)
                Button("Вписать в окно") { model.viewport = ViewportState() }
                    .keyboardShortcut("0", modifiers: .command).disabled(!model.canZoom)
                Button("Реальный размер (100%)") { model.viewport = ViewportState(scale: 1) }
                    .keyboardShortcut("1", modifiers: .command).disabled(!model.canZoom)
                Divider()
                Toggle("Показать сведения", isOn: $model.showMetadata)
                    .keyboardShortcut("i", modifiers: .command)
                Menu("Размер миниатюр в галерее") {
                    Picker("Размер", selection: $model.filmstripSize) {
                        ForEach(FilmstripSize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                    }.pickerStyle(.inline)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Открыть папку…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Открыть библиотеку…") { model.chooseLibrary() }.disabled(model.busy)
                Button("Библиотека") { model.openLibrary() }.disabled(model.busy)
                Button("Импортировать с SD…") { model.chooseImport() }.disabled(model.busy)
                Divider()
                Button("Переместить снимок в Корзину…") { model.confirmTrash() }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(!model.canTrash)
                Button("Обновить") { model.reload() }.keyboardShortcut("r").disabled(model.busy)
            }
        }
    }
}

/// Owns its group backgrounds and spacing so macOS cannot merge adjacent toolbar items.
struct NavigationToolbarView: View {
    @Bindable var model: BrowserModel
    var compact: Bool

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

    private func navigationButton(_ symbol: String, title: String, disabled: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
        .accessibilityLabel(title)
    }

    var body: some View {
        HStack(spacing: 12) {
            group {
                HStack(spacing: 8) {
                    navigationButton("chevron.left", title: "Назад", disabled: model.busy || !model.canBack, action: model.back)
                    navigationButton("chevron.right", title: "Вперёд", disabled: model.busy || !model.canForward, action: model.forward)
                    navigationButton("arrow.up", title: "На уровень выше", disabled: model.busy || !model.canUp, action: model.up)
                }
            }
            group {
                navigationButton("folder.badge.plus", title: "Открыть папку", disabled: model.busy, action: model.chooseFolder)
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
                    Text(model.busy ? model.operationTitle : "\(model.photos.count) фото")
                        .foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: compact ? 90 : 160, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(model.busy ? model.operationTitle : "\(model.photos.count) фото")
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct BrowserView: View {
    @Bindable var model: BrowserModel
    @State private var keyMonitor: Any?
    @State private var contentWidth: CGFloat = 0
    private var compactToolbar: Bool { contentWidth < 1150 }
    private var viewModePicker: some View {
        Picker("Вид", selection: $model.mode) {
            Label("Значки", systemImage: "square.grid.2x2").tag(ViewMode.icons)
            Label("Список", systemImage: "list.bullet").tag(ViewMode.list)
            Label("Колонки", systemImage: "rectangle.split.3x1").tag(ViewMode.columns)
            Label("Галерея", systemImage: "rectangle.bottomthird.inset.filled").tag(ViewMode.gallery)
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
            if !model.catalogIssues.isEmpty {
                HStack {
                    Label("Недоступные файлы: \(model.catalogIssues.count). Остальные фотографии доступны.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Подробнее…") { model.showCatalogIssues() }
                }.font(.callout).padding(10)
                Divider()
            }
            if let error = model.error {
                ContentUnavailableView { Label("Папка недоступна", systemImage: "externaldrive.badge.exclamationmark") } description: { Text(error) } actions: { Button("Повторить") { model.reload() } }
            } else if model.folder == nil {
                ContentUnavailableView { Label("Ваши фотографии", systemImage: "photo.on.rectangle.angled") } description: { Text("Откройте папку или перетащите её сюда.\nJPG и RAF одного снимка будут показаны вместе.") } actions: { Button("Открыть папку…") { model.chooseFolder() }.buttonStyle(.borderedProminent) }
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
            if model.mode != .gallery {
                Divider()
                HStack {
                    Text(model.selected?.name ?? "Нет выделения").lineLimit(1)
                    Spacer()
                    if model.selected?.asset?.isPair == true {
                        Button(model.selection.showsRAW ? "RAW → JPG" : "JPG → RAW") { model.toggleRAW() }
                            .help("Переключить JPEG и проявленный RAW")
                    } else if let asset = model.selected?.asset { Text(asset.kind).foregroundStyle(.secondary) }
                }.font(.callout).padding(10)
            }
        }
        .disabled(model.busy)
        .inspector(isPresented: $model.showMetadata) {
            MetadataSidebar(entry: model.selected, resource: model.selectedResource)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .navigationTitle("")
        .toolbar {
            navigationToolbar
            ToolbarItem(placement: .principal) {
                if compactToolbar {
                    Menu {
                        viewModePicker
                    } label: {
                        Label("Вид", systemImage: viewModeSymbol)
                    }.disabled(model.busy).help("Режим просмотра")
                } else {
                    viewModePicker.pickerStyle(.segmented).frame(width: 180).disabled(model.busy)
                }
            }
            if model.mode == .gallery {
                ToolbarItem {
                    if model.selected?.asset?.isPair == true {
                        Button(model.selection.showsRAW ? "RAW → JPG" : "JPG → RAW") { model.toggleRAW() }
                            .disabled(model.busy).help("Переключить JPEG и проявленный RAW")
                    } else if let asset = model.selected?.asset {
                        Text(asset.kind).foregroundStyle(.secondary)
                    }
                }
                if compactToolbar {
                    ToolbarItem {
                        Menu {
                            Button("Вписать в окно") { model.viewport = ViewportState() }
                            Button("Реальный размер (100%)") { model.viewport = ViewportState(scale: 1) }
                            Divider()
                            Button("Уменьшить") { model.viewport.zoom(by: 1 / 1.4) }
                            Button("Увеличить") { model.viewport.zoom(by: 1.4) }
                        } label: {
                            Label("Масштаб", systemImage: "magnifyingglass")
                        }
                        .disabled(model.busy || !model.canZoom)
                        .help("Масштаб: вписать, 100%, уменьшить или увеличить")
                    }
                } else {
                    ToolbarItemGroup {
                        Button("Вписать") { model.viewport = ViewportState() }
                            .disabled(model.busy || !model.canZoom)
                        Button("100%") { model.viewport = ViewportState(scale: 1) }
                            .disabled(model.busy || !model.canZoom)
                        Button { model.viewport.zoom(by: 1 / 1.4) } label: {
                            Label("Уменьшить", systemImage: "minus.magnifyingglass")
                        }.disabled(model.busy || !model.canZoom)
                        Button { model.viewport.zoom(by: 1.4) } label: {
                            Label("Увеличить", systemImage: "plus.magnifyingglass")
                        }.disabled(model.busy || !model.canZoom)
                    }
                }
            }
            if model.mode == .icons {
                ToolbarItem {
                    Slider(value: $model.iconSize, in: 100...240).frame(width: 100).disabled(model.busy).help("Размер значков")
                }
            }
            ToolbarItem {
                Menu {
                    Button("Имя") { model.setSort(.name) }
                    Button("Тип") { model.setSort(.kind) }
                    Button("Дата изменения") { model.setSort(.modified) }
                    Button("Размер") { model.setSort(.size) }
                } label: { Label("Сортировка", systemImage: "arrow.up.arrow.down") }
                .disabled(model.busy)
            }
            ToolbarItem {
                Button(action: model.confirmTrash) { Label("В Корзину", systemImage: "trash") }
                    .disabled(model.busy || !model.canTrash).help("Переместить все файлы снимка в Корзину (⌘⌫)")
            }
            ToolbarItem {
                Button(action: model.reload) { Label("Обновить", systemImage: "arrow.clockwise") }.disabled(model.busy).help("Обновить")
            }
            ToolbarItem {
                Button { model.showMetadata.toggle() } label: { Label("Сведения", systemImage: "sidebar.right") }
                    .disabled(model.busy).help("Показать или скрыть сведения (⌘I)")
            }
        }

        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
                Task { @MainActor in model.open(url) }
            }
            return true
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard !model.busy, NSApp.keyWindow != nil, NSApp.modalWindow == nil, !(NSApp.keyWindow?.firstResponder is NSTextView), event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                switch event.keyCode {
                case 123: model.step(-1); return nil
                case 124: model.step(1); return nil
                case 49: model.toggleGallery(); return nil
                default: return event
                }
            }
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    }
}

struct Thumbnail: View {
    let asset: PhotoAsset
    @State private var image: RenderedImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4))
            if let image { Image(decorative: image.cgImage, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: failed ? "exclamationmark.triangle" : "photo").foregroundStyle(.secondary) }
        }
        .task(id: asset) {
            image = nil; failed = false
            do { let result = try await ImageService.shared.image(asset.preferred, maxPixel: 480); if !Task.isCancelled { image = result } }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct GalleryView: View {
    @Bindable var model: BrowserModel
    var body: some View {
        VStack(spacing: 0) {
            PreviewPane(model: model)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(model.entries) { entry in
                            VStack(spacing: 4) {
                                if let asset = entry.asset { Thumbnail(asset: asset).frame(width: model.filmstripSize.width, height: model.filmstripSize.imageHeight) }
                                else { Image(systemName: "folder.fill").font(.largeTitle).frame(width: model.filmstripSize.width, height: model.filmstripSize.imageHeight) }
                                Text(entry.name).font(.caption).lineLimit(1).frame(width: model.filmstripSize.width)
                            }.padding(5).background(model.selection.id == entry.id ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .id(entry.id)
                                .onTapGesture(count: 2) { model.activate(entry) }
                                .onTapGesture { model.select(entry.id) }
                        }
                    }.padding(10)
                }.frame(height: model.filmstripSize.stripHeight)
                    .onChange(of: model.selection.id) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: model.filmstripSize) { _, _ in if let id = model.selection.id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

struct PreviewPane: View {
    @Bindable var model: BrowserModel
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = model.preview { ZoomCanvas(image: image.cgImage, state: $model.viewport) }
            else if model.previewLoading { ProgressView("Загрузка изображения…") }
            else if let error = model.previewError { ContentUnavailableView("Не удалось открыть фото", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ContentUnavailableView("Выберите фотографию", systemImage: "photo") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
}
