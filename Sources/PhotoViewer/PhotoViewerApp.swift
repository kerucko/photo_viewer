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
                Button("Обновить") { model.reload() }.keyboardShortcut("r")
            }
        }
    }
}

struct BrowserView: View {
    @Bindable var model: BrowserModel
    @State private var keyMonitor: Any?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(model.folder?.path ?? "Выберите папку с фотографиями").lineLimit(1).truncationMode(.head)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Text("\(model.photos.count) фото").foregroundStyle(.secondary)
            }.font(.callout).padding(.horizontal, 16).padding(.vertical, 9)
            Divider()
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
        .inspector(isPresented: $model.showMetadata) {
            MetadataSidebar(entry: model.selected, resource: model.selectedResource)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.back) { Image(systemName: "chevron.left") }.disabled(!model.canBack).help("Назад")
                Button(action: model.forward) { Image(systemName: "chevron.right") }.disabled(!model.canForward).help("Вперёд")
                Button(action: model.up) { Image(systemName: "arrow.up") }.disabled(model.folder == nil || model.folder?.path == "/").help("На уровень выше")
                Button(action: model.chooseFolder) { Image(systemName: "folder.badge.plus") }.help("Открыть папку")
            }
            ToolbarItem(placement: .principal) {
                Picker("Вид", selection: $model.mode) {
                    Label("Значки", systemImage: "square.grid.2x2").tag(ViewMode.icons)
                    Label("Список", systemImage: "list.bullet").tag(ViewMode.list)
                    Label("Колонки", systemImage: "rectangle.split.3x1").tag(ViewMode.columns)
                    Label("Галерея", systemImage: "rectangle.bottomthird.inset.filled").tag(ViewMode.gallery)
                }.pickerStyle(.segmented).frame(width: 220)
            }
            ToolbarItemGroup {
                if model.mode == .icons { Slider(value: $model.iconSize, in: 100...240).frame(width: 100).help("Размер значков") }
                Menu {
                    Button("Имя") { model.setSort(.name) }
                    Button("Тип") { model.setSort(.kind) }
                    Button("Дата изменения") { model.setSort(.modified) }
                    Button("Размер") { model.setSort(.size) }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                Button(action: model.reload) { Image(systemName: "arrow.clockwise") }.help("Обновить")
                Button { model.showMetadata.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help("Показать или скрыть сведения (⌘I)")
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
                guard NSApp.keyWindow != nil, NSApp.modalWindow == nil, !(NSApp.keyWindow?.firstResponder is NSTextView), event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
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
            HStack {
                Text(model.selection.showsRAW || model.selected?.asset?.jpeg == nil ? "RAW · проявка Core Image" : "JPG").foregroundStyle(.secondary)
                Spacer()
                Button("Вписать") { model.viewport = ViewportState() }
                Button("100%") { model.viewport = ViewportState(scale: 1) }
                Button { model.viewport.zoom(by: 1 / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { model.viewport.zoom(by: 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
            }.padding(10)
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
