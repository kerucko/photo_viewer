import AppKit
import Testing
@testable import PhotoCore
@testable import PhotoViewer

@MainActor struct ImportReportTests {
    @Test func reportStatesHaveAccurateTitlesStyleCountsAndActions() {
        let cases: [(Int, Int, [String], String, NSAlert.Style)] = [
            (2, 0, [], "Импорт завершён", .informational),
            (0, 2, [], "Импорт завершён", .informational),
            (0, 0, [], "Импорт завершён", .informational),
            (0, 0, ["Ошибка"], "Не удалось импортировать фотографии", .warning),
            (1, 0, ["Ошибка"], "Импорт завершён с ошибками", .warning),
            (0, 1, ["Ошибка"], "Импорт завершён с ошибками", .warning)
        ]
        for (imported, skipped, issues, title, style) in cases {
            var report = ImportReport()
            report.imported = imported; report.skipped = skipped; report.issues = issues
            let alert = BrowserModel.makeImportAlert(report)
            #expect(alert.messageText == title)
            #expect(alert.alertStyle == style)
            #expect(alert.informativeText.hasPrefix("Добавлено файлов: \(imported). Пропущено: \(skipped)."))
            #expect(alert.informativeText.contains("Ошибка") == !issues.isEmpty)
            #expect(alert.buttons.map(\.title) == ["Открыть библиотеку", "Закрыть"])
        }
    }

    @Test func reportBoundsLargeFailureList() {
        var report = ImportReport()
        report.issues = (1...416).map { "Не удалось сохранить даты: 17.10/DSCF\($0).JPG" }
        let alert = BrowserModel.makeImportAlert(report)
        #expect(alert.informativeText.contains("DSCF12.JPG"))
        #expect(!alert.informativeText.contains("DSCF13.JPG"))
        #expect(alert.informativeText.contains("И ещё: 404."))
    }

    // Opt-in rendering of the actual NSAlert content, without a modal event loop.
    @Test func renderImportReportsWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["PHOTOVIEWER_IMPORT_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, imported, skipped, failures) in [("failure", 0, 0, 416), ("partial", 10, 2, 416), ("success", 20, 0, 0)] {
            var report = ImportReport()
            report.imported = imported; report.skipped = skipped
            report.issues = (0..<failures).map { "Не удалось сохранить расширенные атрибуты: 17.10/DSCF\($0).RAF" }
            let alert = BrowserModel.makeImportAlert(report)
            alert.layout()
            alert.window.makeKeyAndOrderFront(nil)
            defer { alert.window.orderOut(nil) }
            for _ in 0..<12 {
                alert.window.contentView?.layoutSubtreeIfNeeded()
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
            alert.window.displayIfNeeded()
            let content = try #require(alert.window.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("import-\(name).png"))
            print("Import report render \(name): \(Int(content.bounds.width))×\(Int(content.bounds.height)) pt")
        }
    }
}
