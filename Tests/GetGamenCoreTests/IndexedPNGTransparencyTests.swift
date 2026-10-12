import CoreGraphics
import Foundation
import ImageIO
import XCTest
import GetGamenCore

final class IndexedPNGTransparencyTests: XCTestCase {
    func testSameRGBWithDifferentAlphaRemainsDistinct() throws {
        let alpha: [UInt8] = [0, 1, 127, 128, 254, 255]
        var palette: [UInt8] = []
        for value in alpha { palette.append(contentsOf: [42, 84, 168, value]) }
        let indices: [UInt8] = [0, 1, 2, 3, 4, 5]
        let data = try IndexedPNG.encode(width: 3, height: 2, indices: indices, paletteRGBA: palette)
        let chunks = try pngChunks(data)
        XCTAssertEqual(chunks["IHDR"]?[8], 8)
        XCTAssertEqual(chunks["IHDR"]?[9], 3)
        XCTAssertEqual(chunks["PLTE"], Array(repeating: [UInt8(42), 84, 168], count: 6).flatMap { $0 })
        var encodedAlpha = try XCTUnwrap(chunks["tRNS"])
        XCTAssertLessThanOrEqual(encodedAlpha.count, 6)
        encodedAlpha.append(contentsOf: repeatElement(255, count: max(0, 6 - encodedAlpha.count)))
        XCTAssertEqual(encodedAlpha, alpha)
        XCTAssertEqual(try decodedAlpha(data), alpha)
    }

    func testAll256AlphaValuesSurviveNativeIndexedEncoding() throws {
        var palette: [UInt8] = []
        let alpha = (0...255).map { UInt8($0) }
        for value in alpha { palette.append(contentsOf: [255, 0, 0, value]) }
        let data = try IndexedPNG.encode(width: 16, height: 16, indices: alpha, paletteRGBA: palette)
        let chunks = try pngChunks(data)
        XCTAssertEqual(chunks["IHDR"]?[9], 3)
        XCTAssertEqual(chunks["PLTE"]?.count, 768)
        var encodedAlpha = try XCTUnwrap(chunks["tRNS"])
        XCTAssertLessThanOrEqual(encodedAlpha.count, 256)
        encodedAlpha.append(contentsOf: repeatElement(255, count: max(0, 256 - encodedAlpha.count)))
        XCTAssertEqual(encodedAlpha, alpha)
        XCTAssertEqual(try decodedAlpha(data), alpha)
    }

    func testRGBAInputValidationRejectsMalformedPaletteAndIndices() throws {
        for invalid: [UInt8] in [[], [1, 2, 3], [UInt8](repeating: 255, count: 1028)] {
            XCTAssertThrowsError(try IndexedPNG.encode(width: 1, height: 1, indices: [0], paletteRGBA: invalid)) {
                XCTAssertEqual($0 as? IndexedPNG.EncodingError, .invalidPalette)
            }
        }
        let palette: [UInt8] = [255, 0, 0, 255]
        XCTAssertThrowsError(try IndexedPNG.encode(width: 1, height: 1, indices: [1], paletteRGBA: palette)) {
            XCTAssertEqual($0 as? IndexedPNG.EncodingError, .invalidIndices)
        }
        XCTAssertThrowsError(try IndexedPNG.encode(width: Int.max, height: 2, indices: [], paletteRGBA: palette)) {
            XCTAssertEqual($0 as? IndexedPNG.EncodingError, .invalidDimensions)
        }
        XCTAssertThrowsError(try IndexedPNG.encode(width: 2, height: 1, indices: [0], paletteRGBA: palette))
    }

    private func pngChunks(_ data: Data) throws -> [String: [UInt8]] {
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        var offset = 8
        var chunks: [String: [UInt8]] = [:]
        while offset + 12 <= bytes.count {
            var count = 0
            for byte in bytes[offset..<(offset + 4)] { count = count * 256 + Int(byte) }
            guard count <= bytes.count - offset - 12 else { throw InvalidPNG() }
            let name = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            chunks[name] = Array(bytes[(offset + 8)..<(offset + 8 + count)])
            offset += count + 12
            if name == "IEND" { break }
        }
        return chunks
    }

    private func decodedAlpha(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }
    private struct InvalidPNG: Error { }
}
