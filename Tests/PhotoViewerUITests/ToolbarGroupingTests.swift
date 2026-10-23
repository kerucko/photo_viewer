import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

@MainActor struct ToolbarGroupingTests {
    @Test func navigationHasFourVisuallySeparatedGroups() throws {
        let model = BrowserModel()
        model.open(URL(fileURLWithPath: "/synthetic/photos/исх2"))
        model.loading = false
        model.entries = (0..<50).map {
            let url = URL(fileURLWithPath: "/synthetic/photos/исх2/photo\($0).jpg")
            return CatalogEntry(url: url, asset: PhotoAsset(resources: [PhotoResource(url: url)]))
        }
        for compact in [false, true] {
            let renderer = ImageRenderer(content: NavigationToolbarView(model: model, compact: compact)
                .padding(10).environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            // A scan through the capsules' solid centers must cross four opaque
            // islands with real empty space between them, including name/count.
            let y = image.height / 2
            var runs: [Range<Int>] = []
            var start: Int?
            for x in 0..<image.width {
                let painted = (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
                if painted && start == nil { start = x }
                if !painted, let first = start { runs.append(first..<x); start = nil }
            }
            if let first = start { runs.append(first..<image.width) }
            #expect(runs.count == 4)
            for pair in zip(runs, runs.dropFirst()) {
                #expect(pair.1.lowerBound - pair.0.upperBound >= 20)
            }
            if let directory = ProcessInfo.processInfo.environment["PHOTOVIEWER_TOOLBAR_CAPTURE_DIR"] {
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("toolbar-\(compact ? "compact" : "regular").png"))
            }
        }
    }
}
