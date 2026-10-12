import XCTest
@testable import GetGamenCore

final class PaletteQuantizerTests: XCTestCase {
    func testAll256DistinctColorsAndTransparencyArePreservedExactly() throws {
        var pixels: [UInt8] = []
        for n: Int in 0..<256 {
            let red = UInt8(n)
            let green = UInt8(255 - n)
            let blue = UInt8(n / 2)
            pixels.append(contentsOf: [red, green, blue, red])
        }
        let input = pixels + pixels
        let result = try PaletteQuantizer.quantize(rgba: input)
        XCTAssertEqual(result.paletteRGBA.count, 256 * 4)
        XCTAssertEqual(expand(result), input)
    }

    func testRepeatedTextColorsAndPartialAlphaRemainExact() throws {
        let colors: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255,
                               20, 30, 40, 0, 20, 30, 40, 128]
        let pixels = Array(repeating: colors, count: 1024).flatMap { $0 }
        let result = try PaletteQuantizer.quantize(rgba: pixels)
        XCTAssertEqual(result.paletteRGBA.count, 16)
        XCTAssertEqual(expand(result), pixels)
    }

    func testAdaptiveGradientIsDeterministicAndBounded() throws {
        let pixels = (0..<4096).flatMap { n -> [UInt8] in
            [UInt8((n % 64) * 4), UInt8((n / 64) * 4), 90, 255]
        }
        let original = pixels
        let first = try PaletteQuantizer.quantize(rgba: pixels)
        let second = try PaletteQuantizer.quantize(rgba: pixels)
        XCTAssertEqual(first, second)
        XCTAssertEqual(pixels, original)
        XCTAssertLessThanOrEqual(first.paletteRGBA.count, 1024)
        XCTAssertGreaterThan(first.paletteRGBA.count, 128 * 4)
        XCTAssertEqual(first.indices.count, 4096)
        XCTAssertTrue(first.indices.allSatisfy { Int($0) < first.paletteRGBA.count / 4 })
        let decoded = expand(first)
        var squaredError = 0.0
        for pixel in 0..<4096 {
            XCTAssertEqual(decoded[pixel * 4 + 3], 255)
            for channel in 0..<3 {
                let difference = Double(decoded[pixel * 4 + channel]) - Double(pixels[pixel * 4 + channel])
                squaredError += difference * difference
            }
        }
        // Detect excessive color loss in this two-dimensional gradient.
        XCTAssertLessThan(squaredError / Double(4096 * 3), 30)
    }

    func test257ColorsAreReducedWithoutInvalidIndices() throws {
        let pixels = (0..<257).flatMap { n -> [UInt8] in
            [UInt8(n % 256), UInt8(n / 256), 0, 255]
        }
        let result = try PaletteQuantizer.quantize(rgba: pixels)
        XCTAssertEqual(result.indices.count, 257)
        XCTAssertLessThanOrEqual(result.paletteRGBA.count / 4, 256)
        XCTAssertEqual(expand(result).count, pixels.count)
    }

    func testInvalidBuffersAreRejected() {
        for bytes: [UInt8] in [[], [1], [1, 2, 3], [1, 2, 3, 4, 5]] {
            XCTAssertThrowsError(try PaletteQuantizer.quantize(rgba: bytes)) {
                XCTAssertEqual($0 as? PaletteQuantizer.QuantizationError, .invalidPixels)
            }
        }
    }

    func testLossyPaletteKeepsTransparencyClassesSeparate() throws {
        let pixels = (0..<768).flatMap { n -> [UInt8] in
            [UInt8(n % 256), 80, 160, [UInt8(0), 128, 255][n / 256]]
        }
        let result = try PaletteQuantizer.quantize(rgba: pixels)
        XCTAssertLessThanOrEqual(result.paletteRGBA.count, 1024)
        let expanded = expand(result)
        for pixel in 0..<768 {
            XCTAssertEqual(expanded[pixel * 4 + 3], pixels[pixel * 4 + 3])
        }
    }

    private func expand(_ result: PaletteQuantizer.Result) -> [UInt8] {
        result.indices.flatMap { index in
            let offset = Int(index) * 4
            return Array(result.paletteRGBA[offset..<(offset + 4)])
        }
    }

    func testHiddenColorsDoNotConsumeVisiblePaletteBudget() throws {
        var pixels: [UInt8] = []
        for value: Int in 0..<256 {
            let color: [UInt8] = [UInt8(value), 0, 0, 0]
            for _ in 0..<1024 { pixels.append(contentsOf: color) }
        }
        let visible: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255]
        pixels.append(contentsOf: visible)
        let result = try PaletteQuantizer.quantize(rgba: pixels)
        XCTAssertEqual(result.paletteRGBA.count, 3 * 4)
        XCTAssertEqual(Array(expand(result).suffix(8)), visible)
        for index in result.indices.dropLast(2) {
            XCTAssertEqual(result.paletteRGBA[Int(index) * 4 + 3], 0)
        }
    }
}
