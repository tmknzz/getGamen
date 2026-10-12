import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GetGamen
@testable import GetGamenCore

final class ImageActionsTests: XCTestCase {
    // 4x2: left two columns red, right two columns blue (row-major RGBA).
    private let redBlue: [UInt8] = [
        255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
        255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255
    ]

    func testConvertProducesJpegAndIndexedPng8() throws {
        let png = try solid(width: 5, height: 4, r: 10, g: 150, b: 240)
        let jpeg = try ImageActions.convert(png, format: .jpeg(quality: 0.9))
        let fromJpeg = try RasterImageDecoder.decode(jpeg)
        XCTAssertEqual(fromJpeg.width, 5)
        XCTAssertEqual(fromJpeg.height, 4)
        let png8 = try ImageActions.convert(png, format: .png8)
        XCTAssertEqual([UInt8](png8)[25], 3) // IHDR color type 3 = indexed
        XCTAssertEqual(try RasterImageDecoder.decode(png8).width, 5)
    }

    func testConvertThrowsInvalidQuality() throws {
        let png = try solid(width: 5, height: 4, r: 10, g: 150, b: 240)
        XCTAssertThrowsError(try ImageActions.convert(png, format: .jpeg(quality: 2))) {
            XCTAssertEqual($0 as? ImageActionError, .invalidQuality)
        }
    }

    func testCropReturnsRequestedRegionPixels() throws {
        let data = try imageData(redBlue, width: 4, height: 2)
        let cropped = try ImageActions.crop(data, x: 2, y: 0, width: 2, height: 2)
        let out = try RasterImageDecoder.decode(cropped)
        XCTAssertEqual(out.width, 2)
        XCTAssertEqual(out.height, 2)
        let px = try pixels(cropped)
        for p in stride(from: 0, to: 16, by: 4) {
            XCTAssertEqual(Array(px[p..<p + 4]), [0, 0, 255, 255])
        }
    }

    func testBorderStrokesDefaultOrangeInsideBoundsKeepingCenter() throws {
        let white = try solid(width: 16, height: 16, r: 255, g: 255, b: 255)
        let bordered = try ImageActions.border(white, x: 0, y: 0, width: 16, height: 16)
        let px = try pixels(bordered)
        assertOrange(pixel(px, width: 16, x: 1, y: 1))
        XCTAssertEqual(pixel(px, width: 16, x: 8, y: 8), [255, 255, 255, 255])
    }

    func testRoundedRectangleBorderClampsDefaultCornerRadius() throws {
        let white = try solid(width: 16, height: 16, r: 255, g: 255, b: 255)
        let bordered = try ImageActions.border(white, x: 0, y: 0, width: 16, height: 16,
                                               shape: .roundedRectangle)
        assertOrange(pixel(try pixels(bordered), width: 16, x: 8, y: 1))
    }

    func testRoundedRectangleNegativeCornerRadiusIsClamped() throws {
        let white = try solid(width: 16, height: 16, r: 255, g: 255, b: 255)
        let negative = try ImageActions.border(white, x: 0, y: 0, width: 16, height: 16,
                                               shape: .roundedRectangle, cornerRadius: -5)
        let zero = try ImageActions.border(white, x: 0, y: 0, width: 16, height: 16,
                                           shape: .roundedRectangle, cornerRadius: 0)
        XCTAssertEqual(try pixels(negative), try pixels(zero))
    }

    func testLineWidthControlsStrokeDepth() throws {
        let white = try solid(width: 16, height: 16, r: 255, g: 255, b: 255)
        let thin = try ImageActions.border(white, x: 0, y: 0, width: 16, height: 16, lineWidth: 1)
        let thick = try ImageActions.border(white, x: 0, y: 0, width: 16, height: 16, lineWidth: 6)
        XCTAssertEqual(pixel(try pixels(thin), width: 16, x: 3, y: 8), [255, 255, 255, 255])
        assertOrange(pixel(try pixels(thick), width: 16, x: 3, y: 8))
    }

    func testEllipseBorderLeavesCornersUntouched() throws {
        // Large enough that the corner is ~5px outside the ellipse, clear of its antialiased clip edge.
        let white = try solid(width: 40, height: 20, r: 255, g: 255, b: 255)
        let bordered = try ImageActions.border(white, x: 0, y: 0, width: 40, height: 20, shape: .ellipse)
        let px = try pixels(bordered)
        assertOrange(pixel(px, width: 40, x: 20, y: 0))
        XCTAssertEqual(pixel(px, width: 40, x: 0, y: 0), [255, 255, 255, 255])
        XCTAssertEqual(pixel(px, width: 40, x: 20, y: 10), [255, 255, 255, 255])
    }

    func testCircleBorderZeroesDefaultCornerRadius() throws {
        let white = try solid(width: 10, height: 10, r: 255, g: 255, b: 255)
        let bordered = try ImageActions.border(white, x: 0, y: 0, width: 10, height: 10,
                                               shape: .circle)
        let decoded = try RasterImageDecoder.decode(bordered)
        XCTAssertEqual(decoded.width, 10)
        XCTAssertEqual(decoded.height, 10)
    }

    func testMaskFillsRegionBlackLeavingOutside() throws {
        let white = try solid(width: 8, height: 8, r: 255, g: 255, b: 255)
        let masked = try ImageActions.mask(white, x: 2, y: 2, width: 4, height: 4)
        let px = try pixels(masked)
        XCTAssertEqual(pixel(px, width: 8, x: 3, y: 3), [0, 0, 0, 255])
        XCTAssertEqual(pixel(px, width: 8, x: 0, y: 0), [255, 255, 255, 255])
    }

    func testMosaicKeepsDimensionsAndUniformBlock() throws {
        let data = try imageData(redBlue, width: 4, height: 2)
        let out = try ImageActions.mosaic(data, x: 0, y: 0, width: 4, height: 2, blockSize: 4)
        let decoded = try RasterImageDecoder.decode(out)
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 2)
        let px = try pixels(out)
        XCTAssertEqual(pixel(px, width: 4, x: 0, y: 0), pixel(px, width: 4, x: 3, y: 1))
    }

    func testMosaicLeavesPixelsOutsideRegionUnchanged() throws {
        var bytes = [UInt8]()
        for i in 0..<16 { bytes += [UInt8(i * 16), UInt8(255 - i * 16), UInt8(i * 8), 255] }
        let data = try imageData(bytes, width: 8, height: 2)
        let out = try ImageActions.mosaic(data, x: 0, y: 0, width: 4, height: 2, blockSize: 4)
        let before = try pixels(data), after = try pixels(out)
        for y in 0..<2 {
            for x in 4..<8 { XCTAssertEqual(pixel(after, width: 8, x: x, y: y), pixel(before, width: 8, x: x, y: y)) }
        }
        XCTAssertNotEqual(pixel(after, width: 8, x: 0, y: 0), pixel(before, width: 8, x: 0, y: 0))
    }

    func testOutOfRangeCropAndNonSquareCircleThrowInvalidRegion() throws {
        let data = try solid(width: 8, height: 8, r: 0, g: 0, b: 0)
        XCTAssertThrowsError(try ImageActions.crop(data, x: 4, y: 0, width: 8, height: 2)) {
            XCTAssertEqual($0 as? ImageActionError, .invalidRegion)
        }
        XCTAssertThrowsError(try ImageActions.border(data, x: 0, y: 0, width: 8, height: 4, shape: .circle)) {
            XCTAssertEqual($0 as? ImageActionError, .invalidRegion)
        }
    }

    func testNonImageDataThrowsInvalidImage() {
        let data = Data("not an image".utf8)
        XCTAssertThrowsError(try ImageActions.convert(data, format: .png)) {
            XCTAssertEqual($0 as? ImageActionError, .invalidImage)
        }
        XCTAssertThrowsError(try ImageActions.crop(data, x: 0, y: 0, width: 1, height: 1)) {
            XCTAssertEqual($0 as? ImageActionError, .invalidImage)
        }
    }

    func testMultiFrameImageThrowsMultipleFrames() throws {
        let frame = try RasterImageDecoder.decode(solid(width: 4, height: 4, r: 0, g: 0, b: 0))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, frame, nil)
        CGImageDestinationAddImage(destination, frame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try ImageActions.convert(data as Data, format: .png)) {
            XCTAssertEqual($0 as? ImageActionError, .multipleFrames)
        }
    }

    func testInputDataIsNotMutated() throws {
        let data = try imageData(redBlue, width: 4, height: 2)
        let before = try pixels(data)
        _ = try ImageActions.mask(data, x: 0, y: 0, width: 2, height: 2)
        XCTAssertEqual(try pixels(data), before)
    }

    func testHugeDeclaredDimensionsThrowImageTooLarge() {
        func bigEndianBytes(_ value: UInt32) -> [UInt8] {
            [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        }

        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let bytes = Array(type.utf8) + payload
            var crc: UInt32 = 0xFFFFFFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB88320)
                }
            }
            return bigEndianBytes(UInt32(payload.count)) + bytes + bigEndianBytes(~crc)
        }

        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let ihdr = bigEndianBytes(9000) + bigEndianBytes(9000) + [8, 6, 0, 0, 0]
        data.append(contentsOf: chunk("IHDR", ihdr))
        // Empty zlib stream: dimensions must be rejected before pixel decoding.
        data.append(contentsOf: chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))
        data.append(contentsOf: chunk("IEND", []))

        XCTAssertThrowsError(try ImageActions.crop(data, x: 0, y: 0, width: 1, height: 1)) {
            XCTAssertEqual($0 as? ImageActionError, .imageTooLarge)
        }
    }

    func testOversizedInputThrowsImageTooLarge() {
        XCTAssertThrowsError(try ImageActions.convert(Data(count: RasterImageDecoder.maxFileBytes + 1), format: .png)) {
            XCTAssertEqual($0 as? ImageActionError, .imageTooLarge)
        }
    }

    func testInputAtSizeLimitPassesSizeCheck() {
        XCTAssertThrowsError(try ImageActions.convert(Data(count: RasterImageDecoder.maxFileBytes), format: .png)) {
            XCTAssertEqual($0 as? ImageActionError, .invalidImage)
        }
    }

    func testImageFormatChoiceMapping() throws {
        let cases: [(ImageFormatChoice, String, UTType)] = [
            (.png, "png", .png), (.png8, "png", .png), (.jpeg, "jpg", .jpeg)
        ]
        for (choice, fileExtension, contentType) in cases {
            XCTAssertEqual(choice.fileExtension, fileExtension)
            XCTAssertEqual(choice.contentType, contentType)
        }
        guard case .png = ImageFormatChoice.png.codecFormat(quality: 0.5) else { return XCTFail("png") }
        guard case .png8 = ImageFormatChoice.png8.codecFormat(quality: 0.5) else { return XCTFail("png8") }
        guard case .jpeg(let quality) = ImageFormatChoice.jpeg.codecFormat(quality: 0.5) else { return XCTFail("jpeg") }
        XCTAssertEqual(quality, 0.5)
    }

    func testOutlineShapeChoiceMapping() {
        XCTAssertEqual(OutlineShapeChoice.rectangle.outlineShape, .rectangle)
        XCTAssertEqual(OutlineShapeChoice.roundedRectangle.outlineShape, .roundedRectangle)
        XCTAssertEqual(OutlineShapeChoice.circle.outlineShape, .circle)
        XCTAssertEqual(OutlineShapeChoice.ellipse.outlineShape, .ellipse)
    }

    // MARK: - fixtures

    private func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { bytes += [r, g, b, 255] }
        return try imageData(bytes, width: width, height: height)
    }

    private func imageData(_ bytes: [UInt8], width: Int, height: Int) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try RasterImageCodec.encode(image, format: .png)
    }

    private func pixels(_ data: Data) throws -> [UInt8] {
        let image = try RasterImageDecoder.decode(data)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The default border color (#FF9500), allowing for antialiasing.
    private func assertOrange(_ rgba: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(rgba[0], 240, file: file, line: line)
        XCTAssertEqual(Double(rgba[1]), 149, accuracy: 16, file: file, line: line)
        XCTAssertLessThanOrEqual(rgba[2], 20, file: file, line: line)
    }

    private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<offset + 4])
    }
}
