import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import GetGamenCore

final class EditRendererTests: XCTestCase {
    private let opaque: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
                                    255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255]

    func testEmptyRenderKeepsActualPixelsAlphaDimensionsAndOriginal() throws {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128, 17, 33, 99, 0,
                              0, 0, 255, 64, 255, 255, 255, 255, 0, 0, 0, 255]
        let input = try image(bytes)
        let original = try XCTUnwrap(input.dataProvider?.data) as Data
        let rendered = try EditRenderer.render(original: input, edits: EditState())
        XCTAssertEqual(rendered.width, 3)
        XCTAssertEqual(rendered.height, 2)
        XCTAssertEqual(rendered.bitsPerComponent, 8)
        XCTAssertEqual(rendered.bitsPerPixel, 32)
        XCTAssertEqual(rendered.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertTrue([CGImageAlphaInfo.premultipliedFirst, .premultipliedLast].contains(rendered.alphaInfo))
        let actual = try pixels(rendered)
        for p in 0..<6 {
            let offset = p * 4
            XCTAssertEqual(actual[offset + 3], bytes[offset + 3])
            for c in 0..<3 {
                let expected = Double(bytes[offset + c]) * Double(bytes[offset + 3]) / 255
                XCTAssertEqual(Double(actual[offset + c]), expected, accuracy: 1)
            }
        }
        XCTAssertEqual(try XCTUnwrap(input.dataProvider?.data) as Data, original)
    }

    func testDataRenderUsesUprightDimensionsAndDoesNotRewriteEXIFSource() throws {
        let data = try orientedTIFF()
        let hash = SHA256.hash(data: data)
        let output = try EditRenderer.render(originalData: data, pixelSize: PixelSize(width: 2, height: 3),
                                             edits: EditState())
        // EXIF6 maps ABC/DEF to DA/EB/FC, independently tabulated.
        let positions = [3, 0, 4, 1, 5, 2]
        let expected = positions.flatMap { Array(opaque[($0 * 4)..<($0 * 4 + 4)]) }
        XCTAssertEqual(output.width, 2)
        XCTAssertEqual(output.height, 3)
        XCTAssertEqual(try pixels(output), expected)
        XCTAssertEqual(SHA256.hash(data: data), hash)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try source(data), 0, nil)
                                 as? [String: Any])
        XCTAssertEqual((props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 6)
        XCTAssertThrowsError(try EditRenderer.render(originalData: data,
            pixelSize: PixelSize(width: 3, height: 2), edits: EditState())) {
            XCTAssertEqual($0 as? EditRenderer.RenderingError, .pixelSizeMismatch)
        }
        XCTAssertEqual(SHA256.hash(data: data), hash)
    }

    func testInvalidExpectedSizePrecedesDecodeAndDecoderErrorsPropagate() {
        XCTAssertThrowsError(try EditRenderer.render(originalData: Data(),
            pixelSize: PixelSize(width: 0, height: 2), edits: EditState())) {
            XCTAssertEqual($0 as? DocumentStoreError, .invalidPixelSize)
        }
        XCTAssertThrowsError(try EditRenderer.render(originalData: Data("invalid image".utf8),
            pixelSize: PixelSize(width: 3, height: 2), edits: EditState())) {
            XCTAssertEqual($0 as? RasterImageDecoder.DecodingError, .invalidData)
        }
    }

    func testImageMaskIsNotAcceptedAsAnUprightColorRaster() throws {
        let bytes: [UInt8] = [0, 64, 128, 192, 224, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let mask = try XCTUnwrap(CGImage(maskWidth: 3, height: 2, bitsPerComponent: 8,
                                        bitsPerPixel: 8, bytesPerRow: 3, provider: provider,
                                        decode: nil, shouldInterpolate: false))
        XCTAssertTrue(mask.isMask)
        XCTAssertThrowsError(try EditRenderer.render(original: mask, edits: EditState())) {
            XCTAssertEqual($0 as? EditRenderer.RenderingError, .invalidImage)
        }
    }

    func testSupportedEditsProducePixelsWithoutChangingOriginal() throws {
        let original = try image(opaque)
        let before = try pixels(original)
        let mask = EditState(objects: [object(.grayMask(brightness: 0.4))])
        let result = try EditRenderer.render(original: original, edits: mask)
        let data = try pixels(result)
        for y in 0..<2 {
            for x in 0..<2 { XCTAssertEqual(Array(data[(y * 3 + x) * 4..<(y * 3 + x + 1) * 4]), [102, 102, 102, 255]) }
        }
        XCTAssertEqual(try pixels(original), before)
        let crop = try EditRenderer.render(original: original, edits: EditState(crop: PixelCrop(x: 1, y: 0, width: 2, height: 1)))
        XCTAssertEqual(crop.width, 2); XCTAssertEqual(crop.height, 1)
        XCTAssertEqual(try pixels(crop), Array(before[4..<12]))
    }

    func testEntireEditStateIsValidatedBeforeRendering() throws {
        let outline = OutlineStyle(shape: .rectangle, color: RGBColor(red: 1, green: 0, blue: 0),
                                   lineWidth: 1, cornerRadius: 0)
        let edits = EditState(objects: [object(.outline(outline)), object(.grayMask(brightness: .nan))])
        XCTAssertThrowsError(try EditRenderer.render(original: image(opaque), edits: edits)) {
            XCTAssertEqual($0 as? DocumentStoreError, .invalidEdits)
        }
        XCTAssertThrowsError(try EditRenderer.render(original: image(opaque),
            edits: EditState(crop: PixelCrop(x: 2, y: 0, width: 2, height: 1)))) {
            XCTAssertEqual($0 as? DocumentStoreError, .invalidEdits)
        }
    }

    func testRenderedUprightPixelsAreSharedByActualThreeFormatCodec() throws {
        let data = try orientedTIFF()
        let rendered = try EditRenderer.render(originalData: data,
            pixelSize: PixelSize(width: 2, height: 3), edits: EditState())
        let expected = try pixels(rendered)
        for (format, isLossless) in [(RasterImageCodec.Format.png, true), (.png8, true),
                                     (.jpeg(quality: 0.9), false)] {
            let exported = try RasterImageCodec.encode(rendered, format: format)
            let exportedSource = try source(exported)
            XCTAssertEqual(CGImageSourceGetCount(exportedSource), 1)
            let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(exportedSource, 0, nil))
            XCTAssertEqual(raw.width, 2)
            XCTAssertEqual(raw.height, 3)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(exportedSource, 0, nil)
                                          as? [String: Any])
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1, 1)
            let decoded = try RasterImageDecoder.decode(exported)
            XCTAssertEqual(decoded.width, 2)
            XCTAssertEqual(decoded.height, 3)
            if isLossless { XCTAssertEqual(try pixels(decoded), expected) }
            if case .png8 = format { XCTAssertEqual([UInt8](exported)[25], 3) }
        }
    }

    private func object(_ style: EditStyle) -> EditObject {
        EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 2, height: 2), style: style)
    }

    private func source(_ data: Data) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    }

    private func orientedTIFF() throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output,
            UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(opaque),
                                  [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = output as Data
        let native = try source(data)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(native, 0, nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 6)
        XCTAssertEqual(try pixels(XCTUnwrap(CGImageSourceCreateImageAtIndex(native, 0, nil))), opaque)
        return data
    }

    private func image(_ bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: 12, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                    bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                                        CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
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
}
