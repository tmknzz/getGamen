import AppKit
import XCTest
@testable import GetGamen

/// Math and actual AppKit view construction; these do not simulate physical pinch/display hardware.
@MainActor
final class EditorCanvasTests: XCTestCase {
    func testInitialActualPixelsAndExplicitFitModes() {
        let normal = EditorViewport()
        normal.updateImage(size: CGSize(width: 400, height: 200), cropOrigin: .zero)
        normal.updateLayout(viewportSize: CGSize(width: 200, height: 200), backingScale: 1)
        XCTAssertEqual(normal.mode, .actualPixels)
        XCTAssertEqual(normal.magnification, 1)
        normal.select(.fitWidth)
        normal.updateLayout(viewportSize: CGSize(width: 800, height: 100), backingScale: 1)
        XCTAssertEqual(normal.magnification, 2)
        normal.select(.fitAll)
        XCTAssertEqual(normal.magnification, 0.5)

        let tall = EditorViewport()
        tall.updateLayout(viewportSize: CGSize(width: 200, height: 100), backingScale: 1)
        tall.updateImage(size: CGSize(width: 400, height: 2000), cropOrigin: .zero)
        XCTAssertEqual(tall.mode, .actualPixels)
        XCTAssertEqual(tall.magnification, 1)
        tall.updateLayout(viewportSize: CGSize(width: 200, height: 100), backingScale: 2)
        XCTAssertEqual(tall.magnification, 0.5)
        tall.select(.fitAll)
        XCTAssertEqual(tall.magnification, 0.05)
    }

    func testActualPixelsManualPreservationAndCropCoordinates() {
        let viewport = EditorViewport()
        viewport.updateImage(size: CGSize(width: 400, height: 200), cropOrigin: CGPoint(x: 100, y: 200))
        viewport.updateLayout(viewportSize: CGSize(width: 300, height: 300), backingScale: 2)
        viewport.select(.actualPixels)
        XCTAssertEqual(viewport.magnification, 0.5)
        viewport.updateLayout(viewportSize: CGSize(width: 500, height: 400), backingScale: 1)
        XCTAssertEqual(viewport.magnification, 1)
        viewport.userMagnified(to: 1.75)
        viewport.updateLayout(viewportSize: CGSize(width: 200, height: 150), backingScale: 2)
        viewport.updateImage(size: CGSize(width: 300, height: 600), cropOrigin: CGPoint(x: 100, y: 200))
        XCTAssertEqual(viewport.mode, .manual)
        XCTAssertEqual(viewport.magnification, 1.75)
        XCTAssertEqual(viewport.originalPoint(fromCanvas: CGPoint(x: 3, y: 4)), CGPoint(x: 103, y: 204))
    }

    func testInvalidAndUnmeasuredGeometryDoesNotPoisonModel() {
        let viewport = EditorViewport()
        viewport.updateImage(size: CGSize(width: 20, height: 200), cropOrigin: .zero)
        viewport.updateLayout(viewportSize: .zero, backingScale: 2)
        XCTAssertEqual(viewport.viewportSize, .zero)
        XCTAssertEqual(viewport.magnification, 1)
        viewport.updateLayout(viewportSize: CGSize(width: 100, height: 100), backingScale: 2)
        let size = viewport.imageSize
        let scale = viewport.magnification
        viewport.updateImage(size: CGSize(width: CGFloat.infinity, height: 1), cropOrigin: .zero)
        viewport.updateImage(size: CGSize(width: 1, height: 1), cropOrigin: CGPoint(x: CGFloat.nan, y: 0))
        viewport.updateLayout(viewportSize: CGSize(width: 10, height: -1), backingScale: 1)
        viewport.updateLayout(viewportSize: CGSize(width: 10, height: 10), backingScale: 0)
        viewport.userMagnified(to: .nan)
        viewport.userMagnified(to: 0)
        XCTAssertEqual(viewport.imageSize, size)
        XCTAssertEqual(viewport.viewportSize, CGSize(width: 100, height: 100))
        XCTAssertEqual(viewport.backingScale, 2)
        XCTAssertEqual(viewport.magnification, scale)
    }

    func testNativeImageViewDrawsIndependentCornersUprightAndClears() throws {
        _ = NSApplication.shared
        let image = try corners()
        let sourceBitmap = NSBitmapImageRep(cgImage: image)
        assertColor(sourceBitmap, x: 0, y: 0, expected: [1, 0, 0])
        assertColor(sourceBitmap, x: 3, y: 0, expected: [0, 1, 0])
        assertColor(sourceBitmap, x: 0, y: 3, expected: [0, 0, 1])
        assertColor(sourceBitmap, x: 3, y: 3, expected: [1, 1, 0])
        let view = EditorCanvasImageView(frame: .zero)
        view.update(image)
        XCTAssertTrue(view.isFlipped)
        XCTAssertEqual(view.frame.size, CGSize(width: 4, height: 4))
        let blank = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        // Configure the undrawn destination; never retag pixels after rendering.
        let bitmap = try XCTUnwrap(blank.retagging(with: .sRGB))
        bitmap.size = view.bounds.size
        XCTAssertEqual(bitmap.colorSpace, NSColorSpace.sRGB)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // NSBitmapImageRep rows are top-to-bottom; all four literal provider quadrants differ.
        assertColor(bitmap, x: 0, y: 0, expected: [1, 0, 0])
        assertColor(bitmap, x: bitmap.pixelsWide - 1, y: 0, expected: [0, 1, 0])
        assertColor(bitmap, x: 0, y: bitmap.pixelsHigh - 1, expected: [0, 0, 1])
        assertColor(bitmap, x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1, expected: [1, 1, 0])
        let wrapper = view.previewImage
        view.update(image)
        XCTAssertTrue(wrapper === view.previewImage)
        view.update(nil)
        XCTAssertNil(view.image)
        XCTAssertNil(view.previewImage)
        XCTAssertEqual(view.frame.size, .zero)
    }

    func testNativeCenteringAtDifferentMagnifications() async throws {
        _ = NSApplication.shared
        let model = EditorViewport()
        let scroll = EditorCanvasScrollView(viewport: model)
        defer { scroll.detach() }
        scroll.frame = CGRect(x: 0, y: 0, width: 260, height: 220)
        let image = try corners()
        scroll.update(image: image, cropOrigin: .zero, viewport: model)
        scroll.layoutSubtreeIfNeeded()
        await flushLayout()
        for value in [CGFloat(1), CGFloat(2)] {
            scroll.setMagnification(value, centeredAt: CGPoint(x: scroll.contentView.bounds.midX,
                                                               y: scroll.contentView.bounds.midY))
            scroll.recordNativeMagnification()
            scroll.update(image: image, cropOrigin: .zero, viewport: model)
            await flushLayout()
            scroll.layoutSubtreeIfNeeded()
            let displayed = scroll.imageView.convert(scroll.imageView.bounds, to: scroll)
            let clip = scroll.contentView.frame
            XCTAssertEqual(displayed.width, 4 * value, accuracy: 0.01)
            XCTAssertEqual(displayed.height, 4 * value, accuracy: 0.01)
            XCTAssertEqual(displayed.midX, clip.midX, accuracy: 0.51)
            XCTAssertEqual(displayed.midY, clip.midY, accuracy: 0.51)
        }
    }

    func testInitialActualPixelsCentersSmallImageWithoutLaterLayout() async throws {
        _ = NSApplication.shared
        let model = EditorViewport()
        let scroll = EditorCanvasScrollView(viewport: model)
        defer { scroll.detach() }
        scroll.frame = CGRect(x: 0, y: 0, width: 260, height: 220)
        scroll.update(image: try corners(), cropOrigin: .zero, viewport: model)
        await flushLayout()
        // Pointer hit-testing uses this geometry; no later layout pass may be needed to settle it.
        let displayed = scroll.imageView.convert(scroll.imageView.bounds, to: scroll)
        let clip = scroll.contentView.frame
        XCTAssertEqual(displayed.midX, clip.midX, accuracy: 0.51)
        XCTAssertEqual(displayed.midY, clip.midY, accuracy: 0.51)
        XCTAssertEqual(scroll.contentView.bounds.origin,
                       scroll.contentView.constrainBoundsRect(scroll.contentView.bounds).origin)
    }

    func testNativeConversionAtZoomScrollAndCropOffsets() async throws {
        _ = NSApplication.shared
        let model = EditorViewport()
        let scroll = EditorCanvasScrollView(viewport: model)
        defer { scroll.detach() }
        scroll.frame = CGRect(x: 0, y: 0, width: 180, height: 120)
        let image = try solid(width: 500, height: 400)
        scroll.update(image: image, cropOrigin: CGPoint(x: 100, y: 200), viewport: model)
        scroll.layoutSubtreeIfNeeded()
        await flushLayout()
        for value in [CGFloat(0.5), CGFloat(2)] {
            scroll.setMagnification(value, centeredAt: CGPoint(x: scroll.contentView.bounds.midX,
                                                               y: scroll.contentView.bounds.midY))
            scroll.recordNativeMagnification()
            scroll.update(image: image, cropOrigin: CGPoint(x: 100, y: 200), viewport: model)
            await flushLayout()
            scroll.contentView.scroll(to: CGPoint(x: 40, y: 50))
            scroll.reflectScrolledClipView(scroll.contentView)
            let canvasPoint = CGPoint(x: 83, y: 94)
            let pointInScroll = scroll.convert(canvasPoint, from: scroll.imageView)
            let displaced = scroll.convert(CGPoint(x: 93, y: 104), from: scroll.imageView)
            XCTAssertEqual(abs(displaced.x - pointInScroll.x), 10 * value, accuracy: 0.0001)
            XCTAssertEqual(abs(displaced.y - pointInScroll.y), 10 * value, accuracy: 0.0001)
            let actual = scroll.originalPoint(from: pointInScroll, in: scroll)
            XCTAssertEqual(actual.x, 183, accuracy: 0.0001)
            XCTAssertEqual(actual.y, 294, accuracy: 0.0001)
        }
    }

    func testNativeFitsAndUnchangedImagePreserveManualPosition() async throws {
        _ = NSApplication.shared
        let model = EditorViewport()
        let scroll = EditorCanvasScrollView(viewport: model)
        defer { scroll.detach() }
        scroll.frame = CGRect(x: 0, y: 0, width: 220, height: 180)
        let image = try solid(width: 500, height: 3000)
        scroll.update(image: image, cropOrigin: .zero, viewport: model)
        scroll.layoutSubtreeIfNeeded()
        await flushLayout()
        model.select(.fitAll)
        scroll.update(image: image, cropOrigin: .zero, viewport: model)
        await flushLayout()
        XCTAssertEqual(model.mode, .fitAll)
        XCTAssertLessThan(scroll.magnification, 0.25)
        XCTAssertEqual(scroll.magnification, model.magnification, accuracy: 0.00001)
        // Programmatic native scale plus the actual post-gesture reporting path. Not physical pinch.
        scroll.setMagnification(1.5, centeredAt: CGPoint(x: scroll.contentView.bounds.midX,
                                                       y: scroll.contentView.bounds.midY))
        scroll.recordNativeMagnification()
        XCTAssertEqual(model.mode, .manual)
        XCTAssertEqual(model.magnification, 1.5)
        scroll.contentView.scroll(to: CGPoint(x: 80, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        let wrapper = scroll.imageView.previewImage
        scroll.update(image: image, cropOrigin: .zero, viewport: model)
        await flushLayout()
        XCTAssertTrue(wrapper === scroll.imageView.previewImage)
        XCTAssertEqual(scroll.magnification, 1.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x, accuracy: 0.001)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.001)
    }

    func testLaterNativeMagnificationWinsOverEarlierReportWithoutExpandingLimits() async throws {
        _ = NSApplication.shared
        let model = EditorViewport()
        let scroll = EditorCanvasScrollView(viewport: model)
        defer { scroll.detach() }
        scroll.frame = CGRect(x: 0, y: 0, width: 220, height: 180)
        let image = try solid(width: 500, height: 400)
        scroll.update(image: image, cropOrigin: .zero, viewport: model)
        scroll.layoutSubtreeIfNeeded()
        await flushLayout()
        let minimum = scroll.minMagnification
        let maximum = scroll.maxMagnification
        let center = CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        scroll.setMagnification(1.5, centeredAt: center)
        scroll.recordNativeMagnification()
        XCTAssertEqual(model.mode, .manual)
        XCTAssertEqual(model.magnification, 1.5)
        // Controlled native property changes exercise actual KVO, not a fabricated pinch event.
        scroll.setMagnification(1.25, centeredAt: center)
        XCTAssertEqual(model.magnification, 1.25)
        scroll.update(image: image, cropOrigin: .zero, viewport: model)
        await flushLayout()
        XCTAssertEqual(scroll.magnification, 1.25)
        XCTAssertEqual(model.magnification, 1.25)
        XCTAssertEqual(scroll.minMagnification, minimum)
        XCTAssertEqual(scroll.maxMagnification, maximum)
        scroll.detach()
        scroll.setMagnification(1.75, centeredAt: center)
        await flushLayout()
        XCTAssertEqual(model.magnification, 1.25, "Detached KVO must not update its former model")
    }

    func testTeardownInvalidatesQueuedModelUpdatesAndNativeCallbacks() async throws {
        _ = NSApplication.shared
        let model = EditorViewport()
        let scroll = EditorCanvasScrollView(viewport: model)
        scroll.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        scroll.update(image: try corners(), cropOrigin: CGPoint(x: 10, y: 20), viewport: model)
        scroll.detach()
        await flushLayout()
        scroll.recordNativeMagnification()
        XCTAssertEqual(model.imageSize, .zero)
        XCTAssertEqual(model.cropOrigin, .zero)
        XCTAssertEqual(model.mode, .actualPixels)
    }

    private func flushLayout() async {
        let reached = expectation(description: "scheduled native layout callback drained")
        DispatchQueue.main.async { reached.fulfill() }
        await fulfillment(of: [reached], timeout: 3)
    }

    private func corners() throws -> CGImage {
        let palette: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255],
                                 [0, 0, 255, 255], [255, 255, 0, 255]]
        var bytes: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<4 { bytes += palette[(y / 2) * 2 + x / 2] }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: 16, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func solid(width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func assertColor(_ bitmap: NSBitmapImageRep, x: Int, y: Int, expected: [CGFloat],
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let image = bitmap.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              x >= 0, y >= 0, x < image.width, y < image.height,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                          CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("native bitmap pixel unavailable", file: file, line: line)
            return
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else {
            XCTFail("normalized bitmap pixel unavailable", file: file, line: line)
            return
        }
        let pixel = data.assumingMemoryBound(to: UInt8.self).advanced(by: (y * image.width + x) * 4)
        for channel in 0..<3 {
            XCTAssertEqual(CGFloat(pixel[channel]) / 255, expected[channel], accuracy: 0.02,
                           file: file, line: line)
        }
        XCTAssertEqual(CGFloat(pixel[3]) / 255, 1, accuracy: 0.02, file: file, line: line)
    }
}
