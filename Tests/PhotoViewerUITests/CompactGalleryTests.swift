import AppKit
import SwiftUI
import Testing
@testable import PhotoCore
@testable import PhotoViewer

@MainActor struct CompactGalleryTests {
    @Test func galleryReservesOnlyFilmstripBelowPreview() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let model = BrowserModel()
        model.preview = RenderedImage(cgImage: try #require(context.makeImage()))
        let host = NSHostingView(rootView: GalleryView(model: model))
        func canvas(in view: NSView) -> CanvasView? {
            if let result = view as? CanvasView { return result }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        for width in [850.0, 1180.0, 1900.0] {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
            host.layoutSubtreeIfNeeded()
            let preview = try #require(canvas(in: host))
            #expect(abs(preview.bounds.width - width) < 1)
            // Only the filmstrip and its one-point separator consume height.
            #expect(abs(preview.bounds.height - (700 - model.filmstripSize.stripHeight - 1)) < 1)
        }
    }
}
