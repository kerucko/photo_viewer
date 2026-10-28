import AppKit
import SwiftUI
import PhotoCore

/// Ephemeral gallery state. Each slot owns its request identity, independently of selection.
@MainActor @Observable final class ComparisonSession {
    struct Pane {
        var asset: PhotoAsset
        var showsRAW = false
        var image: RenderedImage?
        var error: String?
        var loading = false
        var request = UUID()
        var resource: PhotoResource { showsRAW ? (asset.raw ?? asset.preferred) : asset.preferred }
    }
    typealias Loader = @Sendable (PhotoResource) async throws -> RenderedImage
    private(set) var panes: [Pane]
    var active: Int
    var viewport = ViewportState()
    private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var geometry: [Int: (CGSize, CGFloat)] = [:]
    private let loader: Loader
    init(assets: [PhotoAsset], primary: String?, loader: @escaping Loader = { try await ImageService.shared.image($0, maxPixel: nil) }) {
        precondition(assets.count == 2 && assets[0].id != assets[1].id)
        panes = assets.map { Pane(asset: $0) }
        active = assets.firstIndex { $0.id == primary } ?? 0
        self.loader = loader
        for index in panes.indices { load(index) }
    }
    var activePane: Pane { panes[active] }
    func cancel() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        for index in panes.indices { panes[index].request = UUID(); panes[index].loading = false }
    }
    func resume() {
        for index in panes.indices where !panes[index].loading && panes[index].image == nil && panes[index].error == nil { load(index) }
    }
    func replace(_ index: Int, with asset: PhotoAsset) {
        guard panes[1 - index].asset.id != asset.id else { active = 1 - index; return }
        panes[index] = Pane(asset: asset)
        load(index)
    }
    func toggleRAW() {
        guard activePane.asset.isPair else { return }
        panes[active].showsRAW.toggle(); load(active)
    }
    func update(_ index: Int, asset: PhotoAsset) {
        guard panes[index].asset != asset else { return }
        panes[index].asset = asset
        if !asset.isPair { panes[index].showsRAW = false }
        load(index)
    }
    func setGeometry(_ size: CGSize, backingScale: CGFloat, for index: Int) {
        geometry[index] = (size, backingScale)
    }
    func zoom(by factor: Double) {
        if viewport.scale == nil {
            guard let image = activePane.image?.cgImage, let (size, backing) = geometry[active], size.width > 0, size.height > 0 else { return }
            viewport.scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height)) * backing
            viewport.fitMultiplier = 1
        }
        viewport.zoom(by: factor)
    }
    private func load(_ index: Int) {
        tasks[index]?.cancel()
        let request = UUID(), resource = panes[index].resource, loader = loader
        panes[index].request = request; panes[index].loading = true
        panes[index].image = nil; panes[index].error = nil
        tasks[index] = Task { [weak self] in
            do {
                let image = try await loader(resource)
                guard !Task.isCancelled, let self, panes[index].request == request else { return }
                panes[index].image = image; panes[index].loading = false
            } catch {
                guard !Task.isCancelled, let self, panes[index].request == request else { return }
                panes[index].error = error.localizedDescription; panes[index].loading = false
            }
        }
    }
}

struct ComparisonView: View {
    @Bindable var model: BrowserModel
    @Bindable var session: ComparisonSession
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<2) { index in
                let pane = session.panes[index]
                VStack(spacing: 0) {
                    HStack {
                        Text(pane.asset.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(pane.resource.isRAW ? "RAW" : "JPG").foregroundStyle(.secondary)
                    }.font(.callout).padding(8)
                    ZStack {
                        Color(nsColor: .underPageBackgroundColor)
                        if let image = pane.image {
                            ZoomCanvas(image: image.cgImage, state: $session.viewport,
                                       canInteract: { !model.busy },
                                       onActivate: { model.activateComparisonPane(index) },
                                       onGeometry: { session.setGeometry($0, backingScale: $1, for: index) },
                                       onMagnify: { factor in model.activateComparisonPane(index); model.zoom(by: factor) })
                        } else if pane.loading { ProgressView("Загрузка изображения…") }
                        else if let error = pane.error {
                            ContentUnavailableView("Не удалось открыть фото", systemImage: "exclamationmark.triangle", description: Text(error))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
                .contentShape(Rectangle())
                .onTapGesture { model.activateComparisonPane(index) }
                .overlay(Rectangle().strokeBorder(session.active == index ? Color.accentColor : Color.clear, lineWidth: 2).allowsHitTesting(false))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
