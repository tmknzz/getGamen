import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import GetGamenCore

final class RasterImageCodecTests: XCTestCase {
    func testPNG8PreservesNormalizedAlphaAndAsymmetricPixels() throws {
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128, 17, 33, 55, 0,
                             0, 0, 255, 255, 255, 255, 255, 64, 60, 90, 120, 255]
        let input = try image(width: 3, height: 2, rgba: rgba)
        let data = try RasterImageCodec.encode(input, format: .png8)
        let bytes = [UInt8](data)
        XCTAssertEqual(bytes[25], 3, "PNG8 must be actual indexed PNG")
        let actual = try pixels(decode(data, type: UTType.png, width: 3, height: 2))
        for pixel in 0..<6 {
            let offset = pixel * 4
            let alpha = Int(rgba[offset + 3])
            XCTAssertEqual(actual[offset + 3], rgba[offset + 3])
            for channel in 0..<3 {
                let expected = Double(Int(rgba[offset + channel]) * alpha) / 255
                XCTAssertEqual(Double(actual[offset + channel]), expected, accuracy: 1)
            }
        }
        XCTAssertEqual(try XCTUnwrap(input.dataProvider?.data) as Data, Data(rgba))
    }

    func testPNG8AdaptivelyReducesMoreThan256Colors() throws {
        var rgba: [UInt8] = []
        for y in 0..<64 {
            for x in 0..<64 { rgba.append(contentsOf: [UInt8(x * 4), UInt8(y * 4), UInt8((x + y) * 2), 255]) }
        }
        let input = try image(width: 64, height: 64, rgba: rgba)
        let data = try RasterImageCodec.encode(input, format: .png8)
        let bytes = [UInt8](data)
        XCTAssertEqual(bytes[25], 3)
        var paletteCount = 0
        var offset = 8
        while offset + 12 <= bytes.count {
            var length = 0
            for byte in bytes[offset..<(offset + 4)] { length = length * 256 + Int(byte) }
            guard length <= bytes.count - offset - 12 else { XCTFail("Invalid PNG chunk"); return }
            if String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) == "PLTE" { paletteCount = length / 3 }
            offset += length + 12
        }
        XCTAssertGreaterThan(paletteCount, 128)
        XCTAssertLessThanOrEqual(paletteCount, 256)
        let actual = try pixels(decode(data, type: UTType.png, width: 64, height: 64))
        var error = 0.0
        for index in 0..<rgba.count where index % 4 != 3 {
            let delta = Double(actual[index]) - Double(rgba[index])
            error += delta * delta
        }
        XCTAssertLessThan(error / Double(64 * 64 * 3), 100)
        XCTAssertTrue(stride(from: 3, to: actual.count, by: 4).allSatisfy { actual[$0] == 255 })
    }

    func testPNGPreservesAsymmetricPixelsAlphaAndInput() throws {
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128, 17, 33, 55, 0,
                             0, 0, 255, 255, 255, 255, 255, 64, 60, 90, 120, 255]
        let input = try image(width: 3, height: 2, rgba: rgba)
        let before = try XCTUnwrap(input.dataProvider?.data) as Data
        let data = try RasterImageCodec.encode(input, format: .png)
        let decoded = try decode(data, type: UTType.png, width: 3, height: 2)
        let actual = try pixels(decoded)
        for pixel in 0..<6 {
            let offset = pixel * 4
            let alpha = Int(rgba[offset + 3])
            XCTAssertEqual(actual[offset + 3], rgba[offset + 3])
            for channel in 0..<3 {
                let expected = Double(Int(rgba[offset + channel]) * alpha) / 255
                XCTAssertEqual(Double(actual[offset + channel]), expected, accuracy: 1)
            }
        }
        XCTAssertEqual(try XCTUnwrap(input.dataProvider?.data) as Data, before)
    }

    func testJPEGUsesWhiteForTransparentAndPartialAlphaWithoutChangingPNG() throws {
        var rgba: [UInt8] = []
        for _ in 0..<64 {
            for x in 0..<96 {
                if x < 32 { rgba.append(contentsOf: [0, 255, 0, 0]) }
                else if x < 64 { rgba.append(contentsOf: [255, 0, 0, 128]) }
                else { rgba.append(contentsOf: [0, 0, 255, 255]) }
            }
        }
        let input = try image(width: 96, height: 64, rgba: rgba)
        let jpeg = try RasterImageCodec.encode(input, format: .jpeg(quality: 1))
        let output = try pixels(decode(jpeg, type: UTType.jpeg, width: 96, height: 64))
        assertPixel(output, width: 96, x: 16, y: 32, expected: [255, 255, 255, 255], tolerance: 3)
        assertPixel(output, width: 96, x: 48, y: 32, expected: [255, 127, 127, 255], tolerance: 3)
        assertPixel(output, width: 96, x: 80, y: 32, expected: [0, 0, 255, 255], tolerance: 3)
        let png = try RasterImageCodec.encode(input, format: .png)
        let pngPixels = try pixels(decode(png, type: UTType.png, width: 96, height: 64))
        XCTAssertEqual(pngPixels[(32 * 96 + 16) * 4 + 3], 0)
        XCTAssertEqual(pngPixels[(32 * 96 + 48) * 4 + 3], 128)
        XCTAssertEqual(try XCTUnwrap(input.dataProvider?.data) as Data, Data(rgba))
    }

    func testJPEGQualityBoundariesRejectNonfiniteAndAffectActualPixels() throws {
        var rgba: [UInt8] = []
        for y in 0..<64 {
            for x in 0..<64 {
                let value = UInt8((x * 73 + y * 29 + x * y * 7) % 256)
                rgba.append(contentsOf: [value, value, value, 255])
            }
        }
        let input = try image(width: 64, height: 64, rgba: rgba)
        for invalid: Double in [-0.01, 1.01, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try RasterImageCodec.encode(input, format: .jpeg(quality: invalid))) {
                XCTAssertEqual($0 as? RasterImageCodec.EncodingError, .invalidQuality)
            }
        }
        let low = try RasterImageCodec.encode(input, format: .jpeg(quality: 0))
        let high = try RasterImageCodec.encode(input, format: .jpeg(quality: 1))
        XCTAssertNotEqual(low, high)
        let lowPixels = try pixels(decode(low, type: UTType.jpeg, width: 64, height: 64))
        let highPixels = try pixels(decode(high, type: UTType.jpeg, width: 64, height: 64))
        func error(_ actual: [UInt8]) -> Double {
            var sum = 0.0
            for index in stride(from: 0, to: rgba.count, by: 4) {
                let delta = Double(actual[index]) - Double(rgba[index])
                sum += delta * delta
            }
            return sum / 4096
        }
        XCTAssertLessThan(error(highPixels), error(lowPixels))
    }

    func testBothFormatsKeepUprightCornerMappingAndDimensions() throws {
        var rgba: [UInt8] = []
        for y in 0..<64 {
            for x in 0..<96 {
                let color: [UInt8]
                if y < 32 { color = x < 48 ? [255, 0, 0, 255] : [0, 255, 0, 255] }
                else { color = x < 48 ? [0, 0, 255, 255] : [255, 255, 0, 255] }
                rgba.append(contentsOf: color)
            }
        }
        let input = try image(width: 96, height: 64, rgba: rgba)
        for format: RasterImageCodec.Format in [.png, .jpeg(quality: 1)] {
            let data = try RasterImageCodec.encode(input, format: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 96)
            XCTAssertEqual(decoded.height, 64)
            let output = try pixels(decoded)
            assertPixel(output, width: 96, x: 16, y: 16, expected: [255, 0, 0, 255], tolerance: 3)
            assertPixel(output, width: 96, x: 80, y: 16, expected: [0, 255, 0, 255], tolerance: 3)
            assertPixel(output, width: 96, x: 16, y: 48, expected: [0, 0, 255, 255], tolerance: 3)
            assertPixel(output, width: 96, x: 80, y: 48, expected: [255, 255, 0, 255], tolerance: 3)
        }
    }

    private func image(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func decode(_ data: Data, type: UTType, width: Int, height: Int) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, type.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        return image
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func assertPixel(_ bytes: [UInt8], width: Int, x: Int, y: Int, expected: [UInt8], tolerance: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        let index = (y * width + x) * 4
        for channel in 0..<4 {
            XCTAssertEqual(Double(bytes[index + channel]), Double(expected[channel]), accuracy: tolerance, file: file, line: line)
        }
    }
}
