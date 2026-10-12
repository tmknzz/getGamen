import CoreGraphics
import Foundation
import XCTest
@testable import GetGamenCore

/// Synthetic composition checks do not constitute native screenshot verification.
final class RegionTileCompositorTests: XCTestCase {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let green: [UInt8] = [0, 255, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]
    private let yellow: [UInt8] = [255, 255, 0, 255]
    private let clear: [UInt8] = [0, 0, 0, 0]

    func testAsymmetricTilesKeepTopLeftPlacementCornersAndTransparentGaps() throws {
        let aBytes = red + green + blue + yellow
        let bBytes: [UInt8] = [64, 0, 0, 128, 0, 0, 0, 0]
        let a = try image(2, 2, aBytes)
        let b = try image(1, 2, bBytes)
        let result = try RegionTileCompositor.compose(
            plan: plan(5, 4, [tile("a", 2, 2, 0, 0, 2, 2), tile("b", 1, 2, 4, 2, 1, 2)]),
            images: ["a": a, "b": b])
        XCTAssertEqual(result.width, 5)
        XCTAssertEqual(result.height, 4)
        XCTAssertEqual(result.bitsPerComponent, 8)
        XCTAssertEqual(result.alphaInfo, .premultipliedLast)
        let bytes = try pixels(result)
        var expected = [UInt8](repeating: 0, count: 5 * 4 * 4)
        for (x, y, color) in [(0, 0, red), (1, 0, green), (0, 1, blue), (1, 1, yellow),
                              (4, 2, [UInt8](arrayLiteral: 64, 0, 0, 128))] {
            expected.replaceSubrange(((y * 5 + x) * 4)..<((y * 5 + x) * 4 + 4), with: color)
        }
        XCTAssertEqual(bytes, expected)
        XCTAssertEqual(try XCTUnwrap(a.dataProvider?.data) as Data, Data(aBytes))
        XCTAssertEqual(try XCTUnwrap(b.dataProvider?.data) as Data, Data(bBytes))
    }

    func testAdjacentNativeAndDoubleSizeTilesHaveNoSeamOrGapBleed() throws {
        let native = try image(2, 4, Array(repeating: red, count: 8).flatMap { $0 })
        let lowerDensity = try image(2, 2, Array(repeating: blue, count: 4).flatMap { $0 })
        let result = try RegionTileCompositor.compose(
            plan: plan(7, 4, [tile("native", 2, 4, 0, 0, 2, 4), tile("scaled", 2, 2, 2, 0, 4, 4)]),
            images: ["native": native, "scaled": lowerDensity])
        let bytes = try pixels(result)
        for y in 0..<4 {
            for x in 0..<7 {
                let expected = x < 2 ? red : (x < 6 ? blue : clear)
                XCTAssertEqual(Array(bytes[((y * 7 + x) * 4)..<((y * 7 + x) * 4 + 4)]), expected)
            }
        }
    }

    func testRequiresExactImageKeysUniqueTilesAndActualNativeDimensions() throws {
        let one = try image(1, 1, red)
        let valid = plan(2, 1, [tile("a", 1, 1, 0, 0, 1, 1)])
        rejects(valid, [:])
        rejects(valid, ["b": one])
        rejects(valid, ["a": one, "extra": one])
        rejects(plan(2, 1, [tile("a", 1, 1, 0, 0, 1, 1), tile("a", 1, 1, 1, 0, 1, 1)]), ["a": one])
        rejects(plan(2, 1, [tile("a", 2, 1, 0, 0, 2, 1)]), ["a": one])
        rejects(plan(2, 1, [tile("a", 0, 1, 0, 0, 1, 1)]), ["a": one])
        rejects(plan(2, 1, [tile("", 1, 1, 0, 0, 1, 1)]), ["": one])
        rejects(plan(2, 1, []), [:])
    }

    func testRejectsOverlappingOrUncontainedDestinationsWithoutArithmeticTraps() throws {
        let one = try image(1, 1, red)
        rejects(plan(3, 3, [tile("a", 1, 1, 0, 0, 2, 2), tile("b", 1, 1, 1, 1, 2, 2)]),
                ["a": one, "b": one])
        let malformed: [(Int, Int, Int, Int)] = [(-1, 0, 1, 1), (0, -1, 1, 1), (0, 0, 0, 1),
                                                 (0, 0, 1, -1), (2, 0, 2, 1), (0, 2, 1, 2),
                                                 (Int.max, 0, 1, 1), (0, Int.max, 1, 1),
                                                 (1, 0, Int.max, 1)]
        for (x, y, width, height) in malformed {
            rejects(plan(3, 3, [tile("a", 1, 1, x, y, width, height)]), ["a": one])
        }
    }

    func testRejectsInvalidOutputAndRowOrTotalByteOverflowBeforeAllocation() throws {
        let one = try image(1, 1, red)
        let tiles = [tile("a", 1, 1, 0, 0, 1, 1)]
        for (width, height) in [(0, 1), (1, 0), (-1, 1), (Int.max, 1), (Int.max / 4, 5)] {
            rejects(plan(width, height, tiles), ["a": one])
        }
        for scale: Double in [0, -1, .nan, .infinity] {
            rejects(plan(1, 1, tiles, scale: scale), ["a": one])
        }
    }

    private func rejects(_ plan: RegionCapturePlan, _ images: [String: CGImage],
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RegionTileCompositor.compose(plan: plan, images: images), file: file, line: line) {
            XCTAssertEqual($0 as? RegionCaptureError, .invalidImage, file: file, line: line)
        }
    }

    private func plan(_ width: Int, _ height: Int, _ tiles: [RegionTile], scale: Double = 2) -> RegionCapturePlan {
        RegionCapturePlan(selection: RegionSelection(schemaVersion: 1, anchorID: "a",
                            dragInAnchor: RegionRect(x: 0, y: 0, width: 1, height: 1), displays: []),
                          outputSize: PixelSize(width: width, height: height), outputScale: scale, tiles: tiles)
    }

    private func tile(_ id: String, _ nativeWidth: Int, _ nativeHeight: Int,
                      _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> RegionTile {
        RegionTile(displayID: id, runtimeID: 1,
                   sourceRect: RegionRect(x: 0, y: 0, width: Double(nativeWidth), height: Double(nativeHeight)),
                   pixelSize: PixelSize(width: nativeWidth, height: nativeHeight),
                   destination: RegionPixelRect(x: x, y: y, width: width, height: height))
    }

    private func image(_ width: Int, _ height: Int, _ bytes: [UInt8]) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        // Inspect actual output storage, respecting row stride, rather than re-drawing with another transform.
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let bytes = [UInt8](data)
        var packed: [UInt8] = []
        for row in 0..<image.height {
            let start = row * image.bytesPerRow
            packed.append(contentsOf: bytes[start..<(start + image.width * 4)])
        }
        return packed
    }
}
