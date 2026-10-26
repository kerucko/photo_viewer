import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PhotoCore

@MainActor @Observable final class ZIPExportSession: Identifiable {
    enum Scope: String, CaseIterable { case selected, whole }
    let id = UUID()
    let location: BrowserModel.Location
    let resources: Set<URL>
    var scope: Scope
    var scans: [Scope: ZIPScan] = [:]
    var extensions: Set<String> = []
    var explicitNone = false
    var progress: ZIPProgress?
    var error: String?
    var result: URL?
    private var cancellation = ZIPCancellation()
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private let finish: () -> Void
    var scan: ZIPScan? { scans[scope] }
    var plan: ZIPPlan? { scan?.plan(including: extensions) }
    var isLibrary: Bool { if case .library = location { true } else { false } }
    var canCreate: Bool { progress == nil && scan != nil && !explicitNone && (plan?.fileCount != 0 || scan?.groups.isEmpty == true) }
    init(location: BrowserModel.Location, assets: [PhotoAsset], finish: @escaping () -> Void) {
        self.location = location
        resources = Set(assets.flatMap(\.resources).map(\.url))
        scope = assets.isEmpty ? .whole : .selected
        self.finish = finish
    }
    func selectScope(_ value: Scope) {
        guard progress == nil else { return }
        scope = value; error = nil; explicitNone = false
        if let scan { extensions = scan.allExtensions; return }
        cancellation = ZIPCancellation()
        operationID = UUID()
        let operationID = operationID
        let token = cancellation, location = location, resources = resources
        progress = ZIPProgress(stage: .scanning)
        task = Task {
            do {
                let source: ZIPSource
                switch location {
                case .library(let root):
                    source = try await PhotoLibrary(root: root).zipSource(selectedResources: value == .selected ? resources : nil)
                case .folder(let root):
                    let paths = value == .selected ? resources.map { $0.lastPathComponent } : nil
                    source = ZIPSource(root: root, relativePaths: paths)
                }
                let scanned = try await Task.detached {
                    try ZIPExporter.scan(source, cancellation: token) { update in
                        Task { @MainActor [weak self] in if let self, self.operationID == operationID, self.progress != nil { self.progress = update } }
                    }
                }.value
                try token.check()
                scans[value] = scanned; extensions = scanned.allExtensions; progress = nil
            } catch is CancellationError { progress = nil; finish() }
            catch { progress = nil; self.error = error.localizedDescription }
        }
    }
    func chooseDestination() {
        guard canCreate, let scan else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = scan.source.archiveName + ".zip"
        panel.title = "Создать ZIP-архив"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
    }
    func export(to url: URL) {
        guard canCreate, let scan else { return }
        let plan = scan.plan(including: extensions, excluding: url)
        cancellation = ZIPCancellation()
        operationID = UUID()
        let operationID = operationID
        let token = cancellation
        error = nil; progress = ZIPProgress(stage: .preparing, total: plan.fileCount)
        task = Task {
            do {
                try await Task.detached {
                    try ZIPExporter.export(plan, to: url, cancellation: token) { update in
                        Task { @MainActor [weak self] in if let self, self.operationID == operationID, self.progress != nil { self.progress = update } }
                    }
                }.value
                progress = nil; result = url
            } catch is CancellationError { progress = nil; finish() }
            catch { progress = nil; self.error = error.localizedDescription }
        }
    }
    func cancel() {
        if progress != nil { cancellation.cancel() }
        else { finish() }
    }
}

struct ZIPExportView: View {
    @Bindable var session: ZIPExportSession
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.result == nil ? "Создать ZIP-архив" : "Архив создан").font(.title2.bold())
            if let result = session.result {
                Text(result.path).textSelection(.enabled).lineLimit(3)
            } else {
                Picker("Содержимое", selection: Binding(get: { session.scope }, set: { session.selectScope($0) })) {
                    Text("Выбранные снимки").tag(ZIPExportSession.Scope.selected).disabled(session.resources.isEmpty)
                    Text(session.isLibrary ? "Вся библиотека" : "Вся папка").tag(ZIPExportSession.Scope.whole)
                }.pickerStyle(.radioGroup).disabled(session.progress != nil)
                if let progress = session.progress {
                    Text(progressTitle(progress)).font(.headline)
                    if progress.stage == .preparing && progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    } else { ProgressView().controlSize(.small) }
                } else if let scan = session.scan {
                    HStack {
                        Text("Типы файлов").font(.headline)
                        Spacer()
                        Button("Все") { session.extensions = scan.allExtensions; session.explicitNone = false }.help("Включить все типы файлов")
                        Button("Ничего") { session.extensions = []; session.explicitNone = true }.help("Снять выбор всех типов файлов")
                    }
                    if scan.groups.isEmpty { Text("Папка пуста. В архиве сохранится структура папок.").foregroundStyle(.secondary) }
                    else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(scan.groups) { group in
                                    Toggle(isOn: Binding(get: { session.extensions.contains(group.extensionName) }, set: { selected in
                                        if selected { session.extensions.insert(group.extensionName) } else { session.extensions.remove(group.extensionName) }
                                        session.explicitNone = session.extensions.isEmpty
                                    })) {
                                        HStack { Text(group.title); Spacer(); Text("\(group.count)").monospacedDigit().foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }.frame(maxHeight: 220)
                    }
                    if let plan = session.plan {
                        Text("Файлов: \(plan.fileCount) · \(ByteCountFormatter.string(fromByteCount: plan.byteCount, countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Divider()
            HStack {
                if let result = session.result {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                        .help("Показать созданный ZIP-архив в Finder")
                }
                Spacer()
                Button(session.result == nil ? "Отмена" : "Готово") { session.cancel() }
                    .keyboardShortcut(.cancelAction).help(session.result == nil ? "Отменить создание архива" : "Закрыть окно архива")
                if session.result == nil {
                    Button("Создать…") { session.chooseDestination() }.buttonStyle(.borderedProminent)
                        .disabled(!session.canCreate).help("Выбрать место сохранения и создать ZIP-архив")
                }
            }
        }.padding(24).frame(width: 480).fixedSize(horizontal: false, vertical: true)
            .interactiveDismissDisabled()
            .onAppear { if session.scan == nil && session.progress == nil { session.selectScope(session.scope) } }
    }
    private func progressTitle(_ value: ZIPProgress) -> String {
        switch value.stage {
        case .scanning: "Сканирование файлов… \(value.completed)"
        case .preparing: "Подготовка файлов: \(value.completed) из \(value.total)"
        case .archiving: "Создание ZIP-архива…"
        }
    }
}
