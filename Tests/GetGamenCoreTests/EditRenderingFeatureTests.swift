import CoreGraphics
import XCTest
@testable import GetGamenCore

final class EditRenderingFeatureTests: XCTestCase {
    func testColorMaskIsOpaqueAndSurvivesSerialization() throws {
        let original = try image(width: 8, height: 6) { _, _ in [0, 0, 255, 255] }
        let mask = EditObject(id: UUID(), bounds: PixelBounds(x: 1.2, y: 0.2, width: 2.2, height: 1.3),
                              style: .colorMask(color: RGBColor(red: 1, green: 0.5, blue: 0)))
        let state = EditState(objects: [mask])
        let decoded = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        let output = try pixels(EditRenderer.render(original: original, edits: decoded))
        for y in 0..<2 { for x in 1..<4 {
            XCTAssertEqual(pixel(output, x: x, y: y, width: 8), [255, 128, 0, 255])
        } }
        XCTAssertEqual(pixel(output, x: 4, y: 1, width: 8), [0, 0, 255, 255])
        var invalid = state
        invalid.objects[0].style = .colorMask(color: RGBColor(red: .nan, green: 0, blue: 0))
        XCTAssertThrowsError(try invalid.validate(pixelSize: PixelSize(width: 8, height: 6)))
    }

    func testEveryOutlineStaysWithinFootprintAndPreservesCenter() throws {
        let original = try image(width: 32, height: 24) { _, _ in [0, 0, 255, 255] }
        for shape: OutlineShape in [.rectangle, .roundedRectangle, .circle, .ellipse] {
            let object = EditObject(id: UUID(), bounds: PixelBounds(x: 4, y: 3, width: 16, height: 16),
                style: .outline(OutlineStyle(shape: shape, color: RGBColor(red: 1, green: 0, blue: 0), lineWidth: 2, cornerRadius: 4)))
            let output = try pixels(EditRenderer.render(original: original, edits: EditState(objects: [object])))
            XCTAssertEqual(pixel(output, x: 12, y: 11, width: 32), [0, 0, 255, 255])
            XCTAssertEqual(pixel(output, x: 2, y: 3, width: 32), [0, 0, 255, 255])
            XCTAssertEqual(pixel(output, x: 12, y: 4, width: 32), [255, 0, 0, 255])
        }
    }

    func testFractionalMaskFullyCoversEveryTouchedPixelAndCropUsesTopLeft() throws {
        let original = try image(width: 8, height: 6) { x, y in [UInt8(x * 20), UInt8(y * 30), 0, 255] }
        let mask = EditObject(id: UUID(), bounds: PixelBounds(x: 1.2, y: 0.2, width: 2.2, height: 1.3), style: .grayMask(brightness: 0.5))
        let output = try pixels(EditRenderer.render(original: original, edits: EditState(objects: [mask])))
        for y in 0..<2 { for x in 1..<4 { XCTAssertEqual(pixel(output, x: x, y: y, width: 8), [128, 128, 128, 255]) } }
        XCTAssertEqual(pixel(output, x: 4, y: 1, width: 8), [80, 30, 0, 255])
        let crop = try EditRenderer.render(original: original, edits: EditState(crop: PixelCrop(x: 2, y: 1, width: 3, height: 2)))
        XCTAssertEqual(crop.width, 3); XCTAssertEqual(crop.height, 2)
        XCTAssertEqual(pixel(try pixels(crop), x: 0, y: 0, width: 3), [40, 30, 0, 255])
    }

    func testHiddenPixelsCannotAffectWholeRenderedOrEncodedImageThroughMosaic() throws {
        var mask = EditObject(id: UUID(), bounds: PixelBounds(x: 9.2, y: 7.2, width: 5.2, height: 8.2), style: .grayMask(brightness: 0.6))
        let mosaic = EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 32, height: 32), style: .mosaic(blockSize: 9))
        let outline = EditObject(id: UUID(), bounds: PixelBounds(x: 7, y: 5, width: 12, height: 15),
            style: .outline(OutlineStyle(shape: .rectangle, color: RGBColor(red: 1, green: 0, blue: 0), lineWidth: 2, cornerRadius: 0)))
        func original(secret: UInt8) throws -> CGImage {
            try image(width: 32, height: 32) { x, y in
                if (9..<15).contains(x), (7..<16).contains(y) { return [secret, 255-secret, secret, 255] }
                return [UInt8((x * 13 + y) % 256), UInt8((x + y * 7) % 256), UInt8((x * 5 + y * 3) % 256), 255]
            }
        }
        let a = try original(secret: 0), b = try original(secret: 255)
        XCTAssertNotEqual(try pixels(a), try pixels(b))
        for style: EditStyle in [.grayMask(brightness: 0.6), .colorMask(color: RGBColor(red: 1, green: 0.5, blue: 0))] {
        mask.style = style
        for crop in [nil, PixelCrop(x: 14, y: 0, width: 18, height: 28)] {
            let edits = EditState(objects: [mask, outline, mosaic], crop: crop)
            let first = try EditRenderer.render(original: a, edits: edits)
            let second = try EditRenderer.render(original: b, edits: edits)
            XCTAssertEqual(try pixels(first), try pixels(second))
            for format: RasterImageCodec.Format in [.png, .png8, .jpeg(quality: 0.3), .jpeg(quality: 0.9)] {
                let x = try RasterImageDecoder.decode(RasterImageCodec.encode(first, format: format))
                let y = try RasterImageDecoder.decode(RasterImageCodec.encode(second, format: format))
                XCTAssertEqual(try pixels(x), try pixels(y))
            }
        }
    }

    }

    func testMosaicFillsEachTopLeftAnchoredBlockWithItsMean() throws {
        // 4px blocks from the top-left: A=(0..<4,0..<4) B=(4..<6,0..<4) C=(0..<4,4) D=(4..<6,4).
        let original = try image(width: 6, height: 5) { x, y in
            [x == 0 && y == 0 ? 255 : 0, x == 5 && y < 4 ? 255 : 0, y == 4 && x != 3 && x != 5 ? 255 : 0, 255]
        }
        let mosaic = EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 6, height: 5), style: .mosaic(blockSize: 4))
        let output = try pixels(EditRenderer.render(original: original, edits: EditState(objects: [mosaic])))
        // Means rounded half up: 255/16, 4*255/8, 3*255/4, 255/2.
        let a: [UInt8] = [16, 0, 0, 255], b: [UInt8] = [0, 128, 0, 255]
        let c: [UInt8] = [0, 0, 191, 255], d: [UInt8] = [0, 0, 128, 255]
        for y in 0..<5 { for x in 0..<6 {
            let expected = y < 4 ? (x < 4 ? a : b) : (x < 4 ? c : d)
            XCTAssertEqual(pixel(output, x: x, y: y, width: 6), expected, "(\(x), \(y))")
        } }
    }

    func testMosaicChangesFineDetailAndGrayPassAlwaysWins() throws {
        let original = try image(width: 32, height: 32) { x, y in ((x+y)%2 == 0) ? [0,0,0,255] : [255,255,255,255] }
        let mosaic = EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 32, height: 32), style: .mosaic(blockSize: 8))
        let rendered = try EditRenderer.render(original: original, edits: EditState(objects: [mosaic]))
        XCTAssertNotEqual(try pixels(rendered), try pixels(original))
        let mask = EditObject(id: UUID(), bounds: PixelBounds(x: 2, y: 2, width: 1, height: 1), style: .grayMask(brightness: 0))
        let masked = try EditRenderer.render(original: original, edits: EditState(objects: [mask, mosaic]))
        XCTAssertEqual(pixel(try pixels(masked), x: 2, y: 2, width: 32), [0,0,0,255])
    }

    private func image(width: Int, height: Int, color: (Int, Int) -> [UInt8]) throws -> CGImage {
        let bytes = (0..<height).flatMap { y in (0..<width).flatMap { x in color(x, y) } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)), decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func pixel(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
        Array(bytes[((y * width + x) * 4)..<((y * width + x + 1) * 4)])
    }
}
