import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GetGamenCore

final class RasterImageDecoderTests: XCTestCase {
    private let colors: [[UInt8]] = [
        [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255],
        [255, 255, 0, 255], [255, 0, 255, 255], [0, 255, 255, 255]
    ]

    func testPixelReaderHasKnownTopRowAndChannelOrder() throws {
        let bytes = colors.flatMap { $0 }
        let control = try image(width: 3, height: 2, bytes: bytes)
        XCTAssertEqual(try XCTUnwrap(control.dataProvider?.data) as Data, Data(bytes))
        XCTAssertEqual(try pixels(control), bytes)
    }

    func testAllEightActualTaggedImagesUseIndependentUprightPixelMatrices() throws {
        // Literal top-row-first oracle, not generated using any orientation API.
        let expected = ["ABCDEF", "CBAFED", "FEDCBA", "DEFABC",
                        "ADBECF", "DAEBFC", "FCEBDA", "CFBEAD"]
        let original = try image(width: 3, height: 2, bytes: colors.flatMap { $0 })
        XCTAssertEqual(try pixels(original), colors.flatMap { $0 }, "Independent raw-row control")
        for orientation in 1...8 {
            let data = try encoded(original, type: .tiff, orientation: orientation)
            let digest = SHA256.hash(data: data)
            let nativeSource = try source(data)
            XCTAssertEqual(CGImageSourceGetCount(nativeSource), 1)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(nativeSource, 0, nil)
                                          as? [String: Any])
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue,
                           orientation, "Fixture must actually carry the requested tag")
            let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(nativeSource, 0, nil))
            XCTAssertEqual(raw.width, 3)
            XCTAssertEqual(raw.height, 2)
            XCTAssertEqual(try pixels(raw), colors.flatMap { $0 },
                           "Fixture encoder must not bake orientation into its pixels")
            let output = try RasterImageDecoder.decode(data)
            XCTAssertEqual(output.width, orientation < 5 ? 3 : 2)
            XCTAssertEqual(output.height, orientation < 5 ? 2 : 3)
            let expectedBytes = expected[orientation - 1].utf8.flatMap { colors[Int($0 - 65)] }
            XCTAssertEqual(try pixels(output), expectedBytes, "EXIF \(orientation)")
            XCTAssertEqual(output.bitsPerComponent, 8)
            XCTAssertEqual(output.colorSpace?.name, CGColorSpace.sRGB)
            XCTAssertEqual(try pixels(RasterImageDecoder.decode(data)), expectedBytes)
            XCTAssertEqual(SHA256.hash(data: data), digest)
            let after = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try source(data), 0, nil)
                                     as? [String: Any])
            XCTAssertEqual((after[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue,
                           orientation, "Original metadata remains unchanged")
        }
    }

    func testMissingOrientationUsesUpWithoutChangingOriginalBytes() throws {
        let data = minimalTIFF(includePixels: true)
        let before = data
        let source = try source(data)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                                      as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyOrientation as String],
                     "Missing-tag evidence must not be an encoder-inserted orientation 1")
        let output = try RasterImageDecoder.decode(data)
        XCTAssertEqual(output.width, 3)
        XCTAssertEqual(output.height, 2)
        XCTAssertEqual(try pixels(output), colors.flatMap { $0 })
        XCTAssertEqual(data, before)
    }

    func testTransparentPNGNormalizesPremultipliedAlphaAndPreservesSource() throws {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128, 37, 21, 99, 0,
                             0, 0, 255, 64, 255, 255, 255, 255, 0, 0, 0, 255]
        let data = try encoded(image(width: 3, height: 2, bytes: bytes), type: .png)
        let before = SHA256.hash(data: data)
        let output = try RasterImageDecoder.decode(data)
        XCTAssertEqual(output.width, 3)
        XCTAssertEqual(output.height, 2)
        XCTAssertEqual(output.bitsPerComponent, 8)
        XCTAssertTrue([CGImageAlphaInfo.premultipliedFirst, .premultipliedLast].contains(output.alphaInfo))
        let actual = try pixels(output)
        for p in 0..<6 {
            let offset = p * 4
            XCTAssertEqual(actual[offset + 3], bytes[offset + 3])
            for c in 0..<3 {
                let premultiplied = Double(bytes[offset + c]) * Double(bytes[offset + 3]) / 255
                XCTAssertEqual(Double(actual[offset + c]), premultiplied, accuracy: 1)
            }
        }
        XCTAssertEqual(SHA256.hash(data: data), before)
    }

    func testJPEGWithRealEXIFRotationHasUprightDimensionsAndUnchangedSource() throws {
        let redPixel: [UInt8] = [255, 0, 0, 255]
        let bytes = Array(repeating: redPixel, count: 96 * 64).flatMap { $0 }
        let input = try image(width: 96, height: 64, bytes: bytes)
        for orientation in [1, 6] {
            let data = try encoded(input, type: .jpeg, orientation: orientation)
            let digest = SHA256.hash(data: data)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try source(data), 0, nil)
                                          as? [String: Any])
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue,
                           orientation)
            let output = try RasterImageDecoder.decode(data)
            XCTAssertEqual(output.width, orientation == 1 ? 96 : 64)
            XCTAssertEqual(output.height, orientation == 1 ? 64 : 96)
            let actual = try pixels(output)
            for c in 0..<4 {
                XCTAssertEqual(Double(actual[c]), Double(bytes[c]), accuracy: 3)
            }
            XCTAssertEqual(SHA256.hash(data: data), digest)
        }
    }

    func testEmptyAndUnrecognizedBytesAreInvalidData() {
        for data in [Data(), Data("not an image".utf8)] {
            XCTAssertThrowsError(try RasterImageDecoder.decode(data)) {
                XCTAssertEqual($0 as? RasterImageDecoder.DecodingError, .invalidData)
            }
        }
    }

    func testActualMultipageContainerIsRejectedWithoutSelectingFirstPage() throws {
        let data = try encoded(image(width: 3, height: 2, bytes: colors.flatMap { $0 }),
                               type: .tiff, count: 2)
        XCTAssertEqual(CGImageSourceGetCount(try source(data)), 2)
        let before = data
        XCTAssertThrowsError(try RasterImageDecoder.decode(data)) {
            XCTAssertEqual($0 as? RasterImageDecoder.DecodingError, .unsupportedImageCount(2))
        }
        XCTAssertEqual(data, before)
    }

    func testRecognizedSingleImageWithCorruptRasterFailsDecoding() throws {
        let valid = try encoded(image(width: 3, height: 2, bytes: colors.flatMap { $0 }), type: .png)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(try source(valid), 0, nil))
        var bytes = [UInt8](valid)
        var offset = 8
        var corrupted = false
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
            guard length <= bytes.count - offset - 12 else {
                XCTFail("Invalid generated PNG chunk length"); return
            }
            if String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) == "IDAT" {
                guard length >= 2 else { XCTFail("Missing zlib header"); return }
                bytes[offset + 8] = 0 // Invalid compression method, not a valid zlib header.
                bytes[offset + 9] = 0
                corrupted = true
                break
            }
            offset += length + 12
        }
        XCTAssertTrue(corrupted, "The encoded fixture must actually contain a corrupted IDAT")
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true
        ]
        for (data, type) in [(Data(bytes), UTType.png), (minimalTIFF(includePixels: false), .tiff)] {
            let nativeSource = try source(data)
            XCTAssertEqual(CGImageSourceGetType(nativeSource) as String?, type.identifier)
            XCTAssertEqual(CGImageSourceGetCount(nativeSource), 1)
            let raw = CGImageSourceCreateImageAtIndex(nativeSource, 0, options as CFDictionary)
            let storage = raw?.dataProvider?.data
            let actualBytes = storage.map { CFDataGetLength($0) } ?? 0
            let requiredBytes = raw.map { $0.bytesPerRow * $0.height } ?? 1
            if type == .tiff {
                // The authored strip begins at EOF and claims 18 bytes. Some ImageIO
                // versions fill missing pixels; buffer length cannot prove source integrity.
                XCTAssertEqual(data.count, 140)
                XCTAssertEqual(Array(data[78..<82]), [140, 0, 0, 0])
                XCTAssertEqual(Array(data[114..<118]), [18, 0, 0, 0])
            } else {
                XCTAssertLessThan(actualBytes, requiredBytes,
                                  "Independently prove native raster data unavailable or incomplete")
            }
            XCTAssertThrowsError(try RasterImageDecoder.decode(data)) {
                XCTAssertEqual($0 as? RasterImageDecoder.DecodingError, .decodingFailed)
            }
        }
    }

    func testEveryTruncatedTIFFStripIsRejectedAndOriginalRemainsUntouched() throws {
        let full = minimalTIFF(includePixels: true)
        for length in 0..<18 {
            let truncated = Data(full.prefix(140 + length))
            let before = truncated
            XCTAssertThrowsError(try RasterImageDecoder.decode(truncated))
            XCTAssertEqual(truncated, before)
        }
        XCTAssertEqual(try RasterImageDecoder.decode(full).width, 3)
        XCTAssertEqual(full, minimalTIFF(includePixels: true))
    }

    // Source-container coverage. ImageIO may expand indexed PNG and choose its own
    // stride; the authored padded CGImage is not proof of native decoded padding.
    func testOddWidthGrayAndIndexedSourcesDoNotRequireRawRGBAStorage() throws {
        let grayBytes: [UInt8] = [0, 64, 128, 99, 99, 192, 224, 255, 99, 99]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(grayBytes) as CFData))
        let gray = try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
                                        bytesPerRow: 5,
                                        space: XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false,
                                        intent: .defaultIntent))
        let grayPNG = try encoded(gray, type: .png)
        let options: [CFString: Any] = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
        let nativeGray = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try source(grayPNG), 0, options as CFDictionary))
        XCTAssertEqual(nativeGray.colorSpace?.model, .monochrome)
        XCTAssertEqual(nativeGray.bitsPerPixel, 8)
        XCTAssertGreaterThanOrEqual(nativeGray.bytesPerRow, 3)
        XCTAssertGreaterThanOrEqual(CFDataGetLength(try XCTUnwrap(nativeGray.dataProvider?.data)), nativeGray.bytesPerRow * nativeGray.height)
        let output = try RasterImageDecoder.decode(grayPNG)
        XCTAssertEqual(output.width, 3)
        XCTAssertEqual(output.height, 2)
        let expectedGray = try pixels(gray)
        let actualGray = try pixels(output)
        for i in expectedGray.indices {
            XCTAssertEqual(Double(actualGray[i]), Double(expectedGray[i]), accuracy: 2)
        }
        let indexed = try RasterImageCodec.encode(
            image(width: 3, height: 2, bytes: colors.flatMap { $0 }), format: .png8)
        XCTAssertEqual([UInt8](indexed)[25], 3, "Actual indexed PNG fixture")
        let decoded = try RasterImageDecoder.decode(indexed)
        XCTAssertEqual(decoded.width, 3)
        XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(try pixels(decoded), colors.flatMap { $0 })
    }

    func testProductionOrientationValidatorRejectsUnrepresentableMetadataScalars() throws {
        // Scalar validation evidence: ImageIO containers may sanitize these values.
        XCTAssertEqual(try RasterImageDecoder.validatedOrientation(nil), 1)
        for n in 1...8 {
            XCTAssertEqual(try RasterImageDecoder.validatedOrientation(NSNumber(value: n)), Int32(n))
        }
        let invalid: [Any] = [true, false, "6", NSNumber(value: 0), NSNumber(value: 9),
                              NSNumber(value: -1), NSNumber(value: 1.5),
                              NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
                              NSDecimalNumber(string: "1.00000000000000000000000001")]
        for value in invalid {
            XCTAssertThrowsError(try RasterImageDecoder.validatedOrientation(value), "\(value)") {
                XCTAssertEqual($0 as? RasterImageDecoder.DecodingError, .invalidOrientation)
            }
        }
    }

    func testProductionDimensionValidatorRejectsNonpositiveAndRGBAOverflow() throws {
        try RasterImageDecoder.validateDimensions(width: 3, height: 2)
        try RasterImageDecoder.validateDimensions(width: 1, height: 1)
        for (width, height) in [(0, 1), (1, 0), (-1, 1), (1, -1),
                                (Int.max / 4 + 1, 1), (Int.max / 4, 2)] {
            XCTAssertThrowsError(try RasterImageDecoder.validateDimensions(width: width, height: height)) {
                XCTAssertEqual($0 as? RasterImageDecoder.DecodingError, .invalidDimensions)
            }
        }
    }

    func testDecodedPixelBudgetRejectsCompressedImageBombDimensions() throws {
        try RasterImageDecoder.validateDimensions(width: 8_000, height: 8_000)
        for size in [(8_001, 8_000), (100_000, 100_000), (1, 64_000_001)] {
            XCTAssertThrowsError(try RasterImageDecoder.validateDimensions(width: size.0, height: size.1))
        }
    }

    func testFileAtByteLimitReadsIdenticalBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-decoder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(0..<8)
        try data.write(to: url)
        XCTAssertEqual(try RasterImageDecoder.readFile(url, limit: 8), data)
    }

    func testFileExceedingByteLimitIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-decoder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(0..<9).write(to: url)
        XCTAssertThrowsError(try RasterImageDecoder.readFile(url, limit: 8)) {
            XCTAssertEqual($0 as? RasterImageDecoder.DecodingError, .fileTooLarge)
        }
    }

    func testOversizedPNGHeaderIsRejectedBeforeDecompression() throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "oversized", withExtension: "png", subdirectory: "Fixtures")))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source(data), 0, nil) as NSDictionary?)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 8_001)
        XCTAssertThrowsError(try RasterImageDecoder.decode(data)) {
            XCTAssertEqual($0 as? RasterImageDecoder.DecodingError, .invalidDimensions)
        }
    }

    private func source(_ data: Data) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    }

    private func image(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                    bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                    bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                                        CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent))
    }

    private func encoded(_ image: CGImage, type: UTType, orientation: Int? = nil,
                         count: Int = 1) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, type.identifier as CFString, count, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        for _ in 0..<count { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Raw provider rows and this CGContext extraction convention are independently
    /// checked by testPixelReaderHasKnownTopRowAndChannelOrder before orientation tests.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// Independently authored little-endian, uncompressed RGB TIFF, no orientation tag.
    /// This controls missing metadata and missing raster without an encoder sanitizing it.
    private func minimalTIFF(includePixels: Bool) -> Data {
        var bytes: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
        func u16(_ value: UInt16) { bytes += [UInt8(value & 255), UInt8(value >> 8)] }
        func u32(_ value: UInt32) {
            bytes += (0..<4).map { UInt8((value >> ($0 * 8)) & 255) }
        }
        let bitsOffset: UInt32 = 8 + 2 + 10 * 12 + 4
        let tags: [(UInt16, UInt16, UInt32, UInt32)] = [
            (256, 4, 1, 3), (257, 4, 1, 2), (258, 3, 3, bitsOffset),
            (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, bitsOffset + 6),
            (277, 3, 1, 3), (278, 4, 1, 2), (279, 4, 1, 18), (284, 3, 1, 1)
        ]
        u16(UInt16(tags.count))
        for (tag, type, count, value) in tags { u16(tag); u16(type); u32(count); u32(value) }
        u32(0)
        u16(8); u16(8); u16(8)
        if includePixels { bytes += colors.flatMap { Array($0.prefix(3)) } }
        return Data(bytes)
    }
}
