import AppKit
import Testing
import PhotoCore
@testable import PhotoViewer

@MainActor struct NativeRegressionTests {
    @Test func collectionItemKeepsLayoutViewWhenContentChanges() {
        let item = PhotoItem()
        let originalView = item.view
        originalView.frame = NSRect(x: 16, y: 16, width: 150, height: 190)
        item.entry = CatalogEntry(url: URL(fileURLWithPath: "/test-folder"))
        item.render()
        #expect(item.view === originalView)
        #expect(item.view.frame == NSRect(x: 16, y: 16, width: 150, height: 190))
        item.isSelected = true
        #expect(item.view === originalView)
        #expect(item.view.frame.size == NSSize(width: 150, height: 190))
    }

    @Test func panningIsInvertedForDragAndScroll() throws {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 70, y: 60), modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down); canvas.mouseDragged(with: drag)
        #expect(canvas.viewport.offset == CGSize(width: -20, height: -10))
        canvas.viewport = ViewportState()
        let cgScroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 12, wheel2: 8, wheel3: 0))
        let scroll = try #require(NSEvent(cgEvent: cgScroll))
        canvas.scrollWheel(with: scroll)
        #expect(canvas.viewport.offset.width > 0)
        #expect(canvas.viewport.offset.height < 0)
    }

    @Test func zoomedImageDoesNotPaintOutsideViewport() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try #require(source.makeImage())
        let output = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        canvas.image = image
        canvas.viewport = ViewportState(scale: 8, offset: CGSize(width: 10, height: -10))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: false)
        output.translateBy(x: 40, y: 40)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(output.data).assumingMemoryBound(to: UInt8.self)
        // The viewport occupies only the central 20×20 square. Everything around
        // it represents adjacent toolbar/filmstrip and must remain transparent.
        for y in 0..<100 {
            for x in 0..<100 {
                let alpha = data[y * 400 + x * 4 + 3]
                if (40..<60).contains(x) && (40..<60).contains(y) { #expect(alpha == 255) }
                else if alpha != 0 { Issue.record("Photo painted outside viewport at (\(x), \(y))"); return }
            }
        }
    }
}
