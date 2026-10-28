import AppKit
import SwiftUI
import PhotoCore

enum PhotoGrid: String, CaseIterable {
    case off, thirds, sixths
    var divisions: Int { switch self { case .off: 0; case .thirds: 3; case .sixths: 6 } }
    var title: String { switch self { case .off: "Выключена"; case .thirds: "3×3"; case .sixths: "6×6" } }
}

/// Presentation choices map to the existing recipe's aspect and portrait fields.
enum EditorAspectChoice: String, CaseIterable {
    case free, original, square, threeTwo, twoThree, fourThree, threeFour, sixteenNine, nineSixteen
    var title: String {
        switch self {
        case .free: "Свободно"; case .original: "Исходные"; case .square: "1:1"
        case .threeTwo: "3:2"; case .twoThree: "2:3"; case .fourThree: "4:3"
        case .threeFour: "3:4"; case .sixteenNine: "16:9"; case .nineSixteen: "9:16"
        }
    }
    var aspect: PhotoAspect {
        switch self {
        case .free: .free; case .original: .original; case .square: .square
        case .threeTwo, .twoThree: .threeTwo
        case .fourThree, .threeFour: .fourThree
        case .sixteenNine, .nineSixteen: .sixteenNine
        }
    }
    var portrait: Bool { self == .twoThree || self == .threeFour || self == .nineSixteen }
    init(edit: PhotoEdit) {
        switch edit.aspect {
        case .free: self = .free; case .original: self = .original; case .square: self = .square
        case .threeTwo: self = edit.portrait ? .twoThree : .threeTwo
        case .fourThree: self = edit.portrait ? .threeFour : .fourThree
        case .sixteenNine: self = edit.portrait ? .nineSixteen : .sixteenNine
        }
    }
}

/// A draft and its asynchronous work belong to one immutable asset snapshot.
@MainActor @Observable final class EditorSession {
    typealias Loader = @Sendable (PhotoResource) async throws -> RenderedImage
    let id = UUID()
    let asset: PhotoAsset
    var draft: PhotoEdit
    private(set) var original: PhotoEdit
    var showsRAW: Bool
    var image: RenderedImage?
    var loading = false
    var saving = false
    var error: String?
    var warning: String?
    private(set) var ready = false
    private var token: PhotoEditToken?
    private let store: PhotoEditStore
    private let loader: Loader
    private var task: Task<Void, Never>?
    private var recipeTask: Task<Void, Never>?
    private var storageError: String?
    private var request = UUID()
    var resource: PhotoResource { showsRAW ? (asset.raw ?? asset.preferred) : asset.preferred }
    var dirty: Bool {
        // Reflection can return crop coordinates with floating-point roundoff.
        // Keep every non-crop field exact, including small intentional angle edits.
        var withoutCrop = draft
        withoutCrop.crop = original.crop
        guard withoutCrop == original else { return true }
        let tolerance = 1e-12
        return ![(draft.crop.x, original.crop.x), (draft.crop.y, original.crop.y),
                 (draft.crop.width, original.crop.width), (draft.crop.height, original.crop.height)]
            .allSatisfy { abs($0.0 - $0.1) <= tolerance }
    }
    var sourceSize: CGSize { image.map { CGSize(width: $0.cgImage.width, height: $0.cgImage.height) } ?? CGSize(width: 1, height: 1) }
    init(asset: PhotoAsset, showsRAW: Bool, initial: PhotoEdit, store: PhotoEditStore,
         loader: @escaping Loader = { try await ImageService.shared.image($0, maxPixel: nil) }) {
        self.asset = asset; self.showsRAW = showsRAW; self.draft = initial; self.original = initial
        self.store = store; self.loader = loader
    }
    func start() {
        recipeTask?.cancel(); task?.cancel(); let request = UUID(); self.request = request; loading = true; error = nil; storageError = nil; ready = false
        recipeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await store.load(for: asset)
                guard !Task.isCancelled, self.request == request else { return }
                token = result.token; draft = result.edit; original = result.edit; warning = result.warning; ready = true
            } catch {
                guard !Task.isCancelled, self.request == request else { return }
                storageError = "Правки недоступны: \(error.localizedDescription)"; self.error = storageError; ready = false
            }
            guard !Task.isCancelled, self.request == request else { return }
            loadImage()
        }
    }
    private func loadImage() {
        let request = UUID(); self.request = request
        task?.cancel(); image = nil; loading = true; error = storageError
        let resource = resource, loader = loader
        task = Task { [weak self] in
            do {
                let image = try await loader(resource)
                guard !Task.isCancelled, let self, self.request == request else { return }
                self.image = image; loading = false
            } catch {
                guard !Task.isCancelled, let self, self.request == request else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
    func toggleRAW() { guard !saving, ready, asset.isPair else { return }; showsRAW.toggle(); loadImage() }
    func setAspect(_ aspect: PhotoAspect) {
        guard ready, image != nil, !saving else { return }
        let portrait = aspect == .original ? ((draft.quarterTurns % 2 == 0) ? sourceSize.height > sourceSize.width : sourceSize.width > sourceSize.height) : draft.portrait
        draft.setAspect(aspect, portrait: portrait, sourceSize: sourceSize)
    }
    var aspectChoice: EditorAspectChoice { EditorAspectChoice(edit: draft) }
    func setAspectChoice(_ choice: EditorAspectChoice) {
        guard ready, image != nil, !saving else { return }
        if choice == .original { setAspect(.original) }
        else { draft.setAspect(choice.aspect, portrait: choice.portrait, sourceSize: sourceSize) }
    }
    var canMirror: Bool { ready && image != nil && !saving }
    func mirrorHorizontally() { guard canMirror else { return }; draft.mirrorHorizontally() }
    func reset() { guard ready, image != nil, !saving else { return }; draft = .identity }
    @discardableResult func save() async -> Bool {
        guard ready, !saving, let token else { return false }
        saving = true; error = nil
        do {
            try await store.save(draft, for: asset, token: token)
            saving = false; cancel(); return true
        } catch { self.error = "Не удалось сохранить: \(error.localizedDescription)"; saving = false; return false }
    }
    func cancel() { recipeTask?.cancel(); recipeTask = nil; task?.cancel(); task = nil; request = UUID() }
}

struct PhotoEditorView: View {
    @Bindable var model: BrowserModel
    @Bindable var session: EditorSession
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = session.image {
                    CropCanvas(image: image.cgImage, edit: $session.draft, grid: model.grid, enabled: !session.saving && session.ready)
                        .padding(18)
                } else if session.loading { ProgressView("Загрузка изображения…") }
                else { ContentUnavailableView("Не удалось открыть фото", systemImage: "exclamationmark.triangle") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = session.error ?? session.warning {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle").lineLimit(3).font(.callout)
                    Spacer(minLength: 8)
                    if !session.ready { Button("Повторить") { session.start() }.help("Повторно загрузить правки и изображение") }
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Кадр", selection: Binding(get: { session.aspectChoice }, set: { session.setAspectChoice($0) })) {
                        ForEach(EditorAspectChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 225).disabled(!session.ready || session.image == nil)
                    Button { session.mirrorHorizontally() } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .foregroundStyle(session.draft.isMirroredHorizontally ? Color.accentColor : Color.primary)
                    }
                        .help("Отразить по горизонтали").accessibilityLabel("Отразить по горизонтали")
                        .accessibilityValue(session.draft.isMirroredHorizontally ? "Включено" : "Выключено")
                        .disabled(!session.canMirror)
                    Divider().frame(height: 20)
                    Button { session.draft.rotateCounterclockwise() } label: { Image(systemName: "rotate.left") }.help("Повернуть влево на 90°").disabled(!session.ready || session.image == nil)
                    Button { session.draft.rotateClockwise() } label: { Image(systemName: "rotate.right") }.help("Повернуть вправо на 90°").disabled(!session.ready || session.image == nil)
                    Spacer(minLength: 8)
                    Picker("Сетка", selection: $model.grid) {
                        ForEach(PhotoGrid.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 165)
                }
                HStack(spacing: 10) {
                    Text("Выравнивание").font(.callout)
                    StraighteningSlider(value: $session.draft.angleDegrees, canEdit: { session.ready && session.image != nil && !session.saving }).frame(minWidth: 90, maxWidth: 220).disabled(!session.ready || session.image == nil)
                    TextField("Угол", value: Binding(get: { session.draft.angleDegrees }, set: { session.draft.angleDegrees = min(45, max(-45, ($0 * 10).rounded() / 10)) }), format: .number.precision(.fractionLength(1)))
                        .frame(width: 52).textFieldStyle(.roundedBorder).disabled(!session.ready || session.image == nil)
                    Text("°").foregroundStyle(.secondary)
                    Button("Сбросить") { session.reset() }.disabled(!session.ready || session.image == nil).help("Сбросить черновик к исходному изображению")
                    Spacer(minLength: 8)
                    if session.asset.isPair {
                        Button(session.showsRAW ? "RAW → JPG" : "JPG → RAW") { session.toggleRAW() }.disabled(!session.ready).help(session.showsRAW ? "Показать JPEG" : "Показать проявленный RAW")
                    }
                    Button("Отмена") { Task { await model.finishEditing(save: false) } }.keyboardShortcut(.cancelAction).help("Закрыть редактор без сохранения правок (Esc)")
                    Button(session.saving ? "Сохранение…" : "Готово") { Task { await model.finishEditing(save: true) } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!session.ready || session.image == nil)
                        .help("Сохранить правки и закрыть редактор (Return)")
                }
            }.padding(12).disabled(session.saving)
        }
    }
}

/// Detect integer boundaries without snapping the tenths-based editing value.
struct AngleBoundaryTracker {
    private(set) var previous: Double?
    mutating func begin(at value: Double) { previous = Self.rounded(value) }
    mutating func end() { previous = nil }
    static func rounded(_ value: Double) -> Double { min(45, max(-45, (value * 10).rounded() / 10)) }
    mutating func update(_ value: Double) -> Bool {
        let value = Self.rounded(value)
        guard let old = previous else { return false }
        previous = value
        return value > old ? floor(value) > floor(old) : (value < old && ceil(value) < ceil(old))
    }
}

struct StraighteningSlider: NSViewRepresentable {
    @Binding var value: Double
    var canEdit: () -> Bool
    var haptic: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> StraighteningSliderView {
        let slider = StraighteningSliderView(value: value, minValue: -45, maxValue: 45, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        slider.setAccessibilityLabel("Выравнивание")
        slider.onBeginDrag = { [weak slider] in
            if let slider { context.coordinator.tracker.begin(at: slider.doubleValue) }
        }
        slider.onEndDrag = { context.coordinator.tracker.end() }
        return slider
    }
    func updateNSView(_ slider: StraighteningSliderView, context: Context) {
        context.coordinator.owner = self
        slider.canEdit = { isEnabled && canEdit() }
        slider.isEnabled = isEnabled && canEdit()
        slider.doubleValue = AngleBoundaryTracker.rounded(value)
        if !slider.isEnabled { context.coordinator.tracker.end() }
    }
    @MainActor final class Coordinator: NSObject {
        var owner: StraighteningSlider?
        var tracker = AngleBoundaryTracker()
        @objc func changed(_ slider: StraighteningSliderView) {
            guard let owner, slider.isEnabled, slider.canEdit() else { return }
            let rounded = AngleBoundaryTracker.rounded(slider.doubleValue)
            slider.doubleValue = rounded
            owner.value = rounded
            if slider.dragging, tracker.update(rounded) { owner.haptic() }
        }
    }
}

@MainActor final class StraighteningSliderView: NSSlider {
    var canEdit: () -> Bool = { true }
    var onBeginDrag: (() -> Void)?
    var onEndDrag: (() -> Void)?
    private(set) var dragging = false
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, canEdit() else { return }
        dragging = true; onBeginDrag?()
        defer { dragging = false; onEndDrag?() }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, canEdit() else { return }
        switch event.keyCode {
        case 123, 125: doubleValue = AngleBoundaryTracker.rounded(doubleValue - 0.1)
        case 124, 126: doubleValue = AngleBoundaryTracker.rounded(doubleValue + 0.1)
        default: super.keyDown(with: event); return
        }
        sendAction(action, to: target)
    }
    override func accessibilityPerformIncrement() -> Bool { adjustAccessibilityAngle(by: 0.1) }
    override func accessibilityPerformDecrement() -> Bool { adjustAccessibilityAngle(by: -0.1) }
    private func adjustAccessibilityAngle(by delta: Double) -> Bool {
        guard isEnabled, canEdit() else { return false }
        doubleValue = AngleBoundaryTracker.rounded(doubleValue + delta)
        sendAction(action, to: target)
        return true
    }
    override func setAccessibilityValue(_ value: Any?) {
        guard isEnabled, canEdit(), let number = value as? NSNumber else { return }
        doubleValue = AngleBoundaryTracker.rounded(number.doubleValue)
        sendAction(action, to: target)
    }
}

struct CropCanvas: NSViewRepresentable {
    let image: CGImage
    @Binding var edit: PhotoEdit
    let grid: PhotoGrid
    var enabled = true
    func makeNSView(context: Context) -> CropCanvasView { CropCanvasView() }
    func updateNSView(_ view: CropCanvasView, context: Context) {
        view.image = image; view.edit = edit; view.grid = grid; view.enabled = enabled
        view.onChange = { edit = $0 }; view.needsDisplay = true
    }
}

/// Native hit testing keeps eight resize targets and the move target unambiguous.
@MainActor final class CropCanvasView: NSView {
    enum Handle: Int, CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move }
    var image: CGImage?
    var edit = PhotoEdit.identity
    var grid = PhotoGrid.off
    var enabled = true
    var onChange: ((PhotoEdit) -> Void)?
    private var drag: (Handle, NSPoint, PhotoCrop)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var geometry: PhotoEditGeometry { PhotoEditGeometry(sourceSize: image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1, height: 1), edit: edit) }
    var safeRect: CGRect {
        let size = geometry.safeSize
        let scale = min(bounds.width / max(1, size.width), bounds.height / max(1, size.height))
        return CGRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2, width: size.width * scale, height: size.height * scale)
    }
    var cropRect: CGRect {
        let rect = safeRect, crop = edit.crop
        return CGRect(x: rect.minX + crop.x * rect.width, y: rect.minY + crop.y * rect.height, width: crop.width * rect.width, height: crop.height * rect.height)
    }
    func point(for handle: Handle) -> CGPoint {
        let r = cropRect
        return switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        case .move: CGPoint(x: r.midX, y: r.midY)
        }
    }
    func handle(at point: CGPoint) -> Handle? {
        for handle in Handle.allCases where handle != .move {
            let p = self.point(for: handle)
            if CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18).contains(point) { return handle }
        }
        return cropRect.contains(point) ? .move : nil
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let safe = safeRect, geometry = geometry
        context.saveGState()
        context.clip(to: safe)
        context.translateBy(x: safe.minX, y: safe.minY)
        context.scaleBy(x: safe.width / geometry.safeSize.width, y: safe.height / geometry.safeSize.height)
        context.concatenate(geometry.sourceToSafeTransform)
        // CGImage is bottom-left; the geometry and crop overlay use top-left.
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
        let crop = cropRect
        context.saveGState()
        let mask = CGMutablePath(); mask.addRect(safe); mask.addRect(crop)
        context.addPath(mask); context.setFillColor(NSColor.black.withAlphaComponent(0.56).cgColor); context.drawPath(using: .eoFill)
        drawPhotoGrid(context, rect: crop, divisions: grid.divisions)
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(1); context.stroke(crop)
        for handle in Handle.allCases where handle != .move {
            let p = point(for: handle)
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        }
        context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let handle = handle(at: p) else { return }
        window?.makeFirstResponder(self); drag = (handle, p, edit.crop)
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, let (handle, start, original) = drag, safeRect.width > 0, safeRect.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil), safe = safeRect
        let dx = (p.x - start.x) / safe.width, dy = (p.y - start.y) / safe.height
        let minimum = 0.01
        if handle == .move {
            edit.crop = PhotoCrop(x: min(1 - original.width, max(0, original.x + dx)), y: min(1 - original.height, max(0, original.y + dy)), width: original.width, height: original.height)
        } else {
            let left = [Handle.topLeft, .left, .bottomLeft].contains(handle)
            let right = [Handle.topRight, .right, .bottomRight].contains(handle)
            let top = [Handle.topLeft, .top, .topRight].contains(handle)
            let bottom = [Handle.bottomLeft, .bottom, .bottomRight].contains(handle)
            var x0 = original.x, y0 = original.y, x1 = original.x + original.width, y1 = original.y + original.height
            if left { x0 = min(x1 - minimum, max(0, x0 + dx)) }
            if right { x1 = max(x0 + minimum, min(1, x1 + dx)) }
            if top { y0 = min(y1 - minimum, max(0, y0 + dy)) }
            if bottom { y1 = max(y0 + minimum, min(1, y1 + dy)) }
            if edit.aspect != .free {
                // Preserve the current pixel ratio; anchor the opposite handle.
                let ratio = original.width / original.height
                var w = x1 - x0, h = y1 - y0
                if (left || right) && !(top || bottom) { h = w / ratio }
                else if (top || bottom) && !(left || right) { w = h * ratio }
                else if abs(dx) > abs(dy) { h = w / ratio } else { w = h * ratio }
                let anchorX = left ? original.x + original.width : right ? original.x : original.x + original.width / 2
                let anchorY = top ? original.y + original.height : bottom ? original.y : original.y + original.height / 2
                let maxW = left ? anchorX : right ? 1 - anchorX : 2 * min(anchorX, 1 - anchorX)
                let maxH = top ? anchorY : bottom ? 1 - anchorY : 2 * min(anchorY, 1 - anchorY)
                let factor = min(1, maxW / max(w, minimum), maxH / max(h, minimum)); w *= factor; h *= factor
                x0 = left ? anchorX - w : right ? anchorX : anchorX - w / 2
                y0 = top ? anchorY - h : bottom ? anchorY : anchorY - h / 2
                x1 = x0 + w; y1 = y0 + h
            }
            let w = min(1, x1 - x0), h = min(1, y1 - y0)
            edit.crop = PhotoCrop(x: max(0, min(1 - w, x0)), y: max(0, min(1 - h, y0)), width: w, height: h)
        }
        onChange?(edit); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { drag = nil }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsDisplay = true }
}

@MainActor func drawPhotoGrid(_ context: CGContext, rect: CGRect, divisions: Int) {
    guard divisions > 1 else { return }
    context.saveGState(); context.clip(to: rect)
    for index in 1..<divisions {
        let fraction = CGFloat(index) / CGFloat(divisions)
        context.move(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.minY)); context.addLine(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.maxY))
        context.move(to: CGPoint(x: rect.minX, y: rect.minY + fraction * rect.height)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fraction * rect.height))
    }
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor); context.setLineWidth(2); context.strokePath()
    for index in 1..<divisions {
        let fraction = CGFloat(index) / CGFloat(divisions)
        context.move(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.minY)); context.addLine(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.maxY))
        context.move(to: CGPoint(x: rect.minX, y: rect.minY + fraction * rect.height)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fraction * rect.height))
    }
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor); context.setLineWidth(0.75); context.strokePath(); context.restoreGState()
}

/// Preserve SwiftUI's existing window delegate while intercepting dirty close requests.
struct EditorWindowGuard: NSViewRepresentable {
    let model: BrowserModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.model = model
        DispatchQueue.main.async {
            guard let window = view.window, window.delegate !== context.coordinator else { return }
            context.coordinator.prior = window.delegate; window.delegate = context.coordinator
        }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var model: BrowserModel
        // AppKit queries NSObject forwarding through nonisolated overrides.
        nonisolated(unsafe) weak var prior: (any NSWindowDelegate)?
        private var closing = false
        init(model: BrowserModel) { self.model = model }
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return prior?.responds(to: selector) ?? false
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            prior?.responds(to: selector) == true ? prior : super.forwardingTarget(for: selector)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if closing || model.editor == nil { return prior?.windowShouldClose?(sender) ?? true }
            model.requestClose { [weak self, weak sender] allowed in
                guard allowed, let self, let sender else { return }
                closing = true; sender.performClose(nil); closing = false
            }
            return false
        }
    }
}

@MainActor final class PhotoViewerLifecycle: NSObject, NSApplicationDelegate {
    static weak var model: BrowserModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.editor != nil else { return .terminateNow }
        Task { @MainActor in model.requestClose { sender.reply(toApplicationShouldTerminate: $0) } }
        return .terminateLater
    }
}
