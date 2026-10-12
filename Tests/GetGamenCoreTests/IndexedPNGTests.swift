import Foundation
import ImageIO
import XCTest
@testable import GetGamenCore

final class IndexedPNGTests: XCTestCase {
    func testAsymmetricPixelsRoundTripWithoutColorOrOrderChanges() throws {
        let palette: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255]
        let indices: [UInt8] = [0, 1, 2, 2, 0, 1]
        let data = try IndexedPNG.encode(width: 3, height: 2, indices: indices, paletteRGB: palette)
        try assertIndexed(data, width: 3, height: 2, expectedColors: 3)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: 24)
        try pixels.withUnsafeMutableBytes { buffer in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 3, height: 2,
                                                 bitsPerComponent: 8, bytesPerRow: 12, space: space,
                                                 bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 3, height: 2))
        }
        let expected = indices.flatMap { index -> [UInt8] in
            let start = Int(index) * 3
            return Array(palette[start..<(start + 3)]) + [255]
        }
        XCTAssertEqual(pixels, expected)
    }

    func testTwoColorImageIsReallyIndexedPNG() throws {
        let data = try IndexedPNG.encode(width: 2, height: 2, indices: [0, 1, 1, 0], paletteRGB: [0, 0, 0, 255, 0, 0])
        try assertIndexed(data, width: 2, height: 2, expectedColors: 2)
    }

    func testAll256PaletteEntriesAreSupported() throws {
        let indices = (0...255).map { UInt8($0) }
        let palette = indices.flatMap { [$0, 255 - $0, $0] }
        let data = try IndexedPNG.encode(width: 256, height: 1, indices: indices, paletteRGB: palette)
        try assertIndexed(data, width: 256, height: 1, expectedColors: 256)
    }

    func testRejectsInvalidPaletteAndOutOfRangeIndex() {
        XCTAssertThrowsError(try IndexedPNG.encode(width: 1, height: 1, indices: [0], paletteRGB: []))
        XCTAssertThrowsError(try IndexedPNG.encode(width: 1, height: 1, indices: [0], paletteRGB: Array(repeating: 0, count: 771)))
        XCTAssertThrowsError(try IndexedPNG.encode(width: 1, height: 1, indices: [1], paletteRGB: [0, 0, 0]))
    }

    func testRejectsIncompleteRGBPaletteEntry() {
        for count in [1, 2, 4, 767] {
            XCTAssertThrowsError(try IndexedPNG.encode(width: 1, height: 1, indices: [0], paletteRGB: Array(repeating: 0, count: count))) {
                XCTAssertEqual($0 as? IndexedPNG.EncodingError, .invalidPalette)
            }
        }
    }

    func testRejectsInvalidDimensionsAndPixelCount() {
        XCTAssertThrowsError(try IndexedPNG.encode(width: 0, height: 1, indices: [], paletteRGB: [0, 0, 0]))
        XCTAssertThrowsError(try IndexedPNG.encode(width: Int.max, height: 2, indices: [], paletteRGB: [0, 0, 0]))
        XCTAssertThrowsError(try IndexedPNG.encode(width: 2, height: 2, indices: [0], paletteRGB: [0, 0, 0]))
    }

    private func assertIndexed(_ data: Data, width: Int, height: Int, expectedColors: Int) throws {
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        guard bytes.count >= 33 else { return XCTFail("Missing PNG IHDR") }
        XCTAssertEqual(bytes[25], 3, "PNG must be indexed color, not RGB/RGBA")
        XCTAssertLessThanOrEqual(bytes[24], 8)
        var offset = 8
        var paletteEntries: Int?
        while offset <= bytes.count - 12 {
            let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= bytes.count - offset - 12 else { return XCTFail("Truncated PNG chunk") }
            let name = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)
            if name == "PLTE" {
                XCTAssertEqual(length % 3, 0)
                paletteEntries = length / 3
            }
            offset += length + 12
        }
        XCTAssertEqual(paletteEntries, expectedColors)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
    }
}
