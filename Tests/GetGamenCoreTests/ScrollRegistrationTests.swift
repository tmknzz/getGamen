import CoreGraphics
import Foundation
import XCTest
@testable import GetGamenCore

final class ScrollRegistrationTests: XCTestCase {
    func testRealVisionForwardTranslationAndExactComposition() throws {
        let previousPixels = pixels()
        let currentPixels = pixels(yOffset: 37)
        let previous = try image(previousPixels)
        let current = try image(currentPixels)
        let raw = try ScrollRegistration.translation(previous: previous, current: current)
        print("Vision forward raw translation: tx=\(raw.tx), ty=\(raw.ty)")
        XCTAssertEqual(raw.tx, 0, accuracy: 1)
        XCTAssertEqual(raw.ty, -37, accuracy: 2)
        guard case let .append(match) = ScrollRegistration.match(previous: previous, current: current) else {
            return XCTFail("Known forward overlap was not accepted")
        }
        XCTAssertEqual(match.appendedHeight, 37)
        XCTAssertEqual(match.overlapHeight, 219)
        XCTAssertEqual(match.meanResidual, 0, accuracy: 0.001)
        let tail = currentPixels.suffix(match.appendedHeight * 128 * 4)
        XCTAssertEqual(previousPixels + tail, pixels(height: 293))
        XCTAssertEqual(previousPixels, pixels())
    }

    func testReverseDirectionIsRejected() throws {
        let earlier = try image(pixels())
        let later = try image(pixels(yOffset: 37))
        let raw = try ScrollRegistration.translation(previous: later, current: earlier)
        print("Vision reverse raw translation: tx=\(raw.tx), ty=\(raw.ty)")
        XCTAssertEqual(raw.ty, 37, accuracy: 2)
        assertRejected(ScrollRegistration.match(previous: later, current: earlier))
    }

    func testHorizontalDisplacementIsRejected() throws {
        assertRejected(ScrollRegistration.match(previous: try image(pixels()),
            current: try image(pixels(xOffset: 12, yOffset: 37))))
    }

    func testUnrelatedAndInsufficientOverlapAreRejected() throws {
        let first = try image(pixels())
        assertRejected(ScrollRegistration.match(previous: first, current: try image(pixels(yOffset: 600))))
        assertRejected(ScrollRegistration.match(previous: first, current: try image(pixels(yOffset: 230))))
    }

    func testIdenticalFrameDoesNotAppend() throws {
        let first = try image(pixels())
        guard case .unchanged = ScrollRegistration.match(previous: first, current: first) else {
            return XCTFail("Identical frame must not append")
        }
    }

    func testRepeatingRowsAreNotAcceptedAsUniqueOverlap() throws {
        let first = try image(pixels(period: 32))
        let second = try image(pixels(yOffset: 8, period: 32))
        assertRejected(ScrollRegistration.match(previous: first, current: second))
    }

    func testStationaryHeaderAndDynamicPatchAreRejected() throws {
        let original = pixels()
        var withHeader = pixels(yOffset: 37)
        withHeader.replaceSubrange(0..<(128 * 24 * 4), with: original.prefix(128 * 24 * 4))
        assertRejected(ScrollRegistration.match(previous: try image(original), current: try image(withHeader)))
        var changed = pixels(yOffset: 37)
        for row in 80..<88 {
            for column in 55..<65 {
                let offset = (row * 128 + column) * 4
                changed[offset] = 255 - changed[offset]
                changed[offset + 1] = 255 - changed[offset + 1]
                changed[offset + 2] = 255 - changed[offset + 2]
            }
        }
        assertRejected(ScrollRegistration.match(previous: try image(original), current: try image(changed)))
    }

    func testDimensionsAreRejectedBeforeRegistration() throws {
        let first = try image(pixels())
        let small = try image(pixels(height: 128), height: 128)
        guard case .reject(.dimensions) = ScrollRegistration.match(previous: first, current: small) else {
            return XCTFail("Mismatching dimensions must reject")
        }
    }

    func testAlmostBlankOverlapDoesNotProvideEnoughEvidence() throws {
        var blank = [UInt8](repeating: 40, count: 128 * 256 * 4)
        for offset in stride(from: 3, to: blank.count, by: 4) { blank[offset] = 255 }
        var previous = blank
        var current = blank
        previous[(100 * 128 + 64) * 4] = 200
        current[(63 * 128 + 64) * 4] = 200
        assertRejected(ScrollRegistration.match(previous: try image(previous), current: try image(current)))
    }

    func testLateMismatchScanRejectsWhenSharedWorkBudgetIsExhausted() throws {
        var repeated: [UInt8] = []
        for _ in 0..<512 {
            for x in 0..<128 {
                let value: UInt8 = (x / 8).isMultiple(of: 2) ? 40 : 220
                repeated.append(contentsOf: [value, value, value, 255])
            }
        }
        var previous = repeated
        var current = repeated
        // Column 73 is between the sample columns; each wrong full comparison
        // reaches almost the bottom before encountering this distinguishing pixel.
        previous[(432 * 128 + 73) * 4] = 100
        current[(395 * 128 + 73) * 4] = 100
        let decision = ScrollRegistration.validate(previous: try image(previous, height: 512),
            current: try image(current, height: 512),
            translation: CGAffineTransform(translationX: 0, y: -37))
        guard case .reject(.unreliable) = decision else {
            return XCTFail("Budget exhaustion must reject, never append the validated candidate")
        }
    }

    func testInjectedProposalUsesSameValidationAndRejectsNonfiniteValues() throws {
        let first = try image(pixels())
        let second = try image(pixels(yOffset: 37))
        guard case .append = ScrollRegistration.validate(previous: first, current: second,
            translation: CGAffineTransform(translationX: 0, y: -37)) else {
            return XCTFail("Normal overlap must fit the validation budget")
        }
        assertRejected(ScrollRegistration.validate(previous: first, current: second,
            translation: CGAffineTransform(translationX: .nan, y: -37)))
        assertRejected(ScrollRegistration.validate(previous: first, current: second,
            translation: CGAffineTransform(translationX: 0, y: -.infinity)))
    }

    func testStationaryPeriodicFrameWithTinyChangesIsAmbiguous() throws {
        let previous = pixels(period: 128)
        var current = previous
        for offset in current.indices where offset % 4 != 3 {
            current[offset] = UInt8(min(255, Int(current[offset]) + 1))
        }
        let result = ScrollRegistration.validate(previous: try image(previous), current: try image(current),
            translation: CGAffineTransform(translationX: 0, y: -128))
        guard case .reject(.ambiguous) = result else {
            return XCTFail("Zero displacement also explains this image; it must not append")
        }
    }

    func testPeriodicBackwardAlternativeIsAmbiguous() throws {
        let previous = try image(pixels(period: 200))
        let current = try image(pixels(yOffset: 150, period: 200))
        let result = ScrollRegistration.validate(previous: previous, current: current,
            translation: CGAffineTransform(translationX: 0, y: -150))
        guard case .reject(.ambiguous) = result else {
            return XCTFail("Forward150 and backward50 are indistinguishable and must not append")
        }
    }

    func testZeroAlternativeIsCheckedEvenWhenBackwardPeriodDoesNotMatch() throws {
        var previous = pixels(period: 128)
        for offset in previous.indices where offset % 4 != 3 {
            let row = offset / (128 * 4)
            previous[offset] = UInt8(Int(previous[offset]) % 200 + (row >= 128 ? 3 : 0))
        }
        var current = previous
        for offset in current.indices where offset % 4 != 3 { current[offset] += 3 }
        // +128 differs by 0, zero by 3, and -128 by 6 (outside tolerance).
        let result = ScrollRegistration.validate(previous: try image(previous), current: try image(current),
            translation: CGAffineTransform(translationX: 0, y: -128))
        guard case .reject(.ambiguous) = result else {
            return XCTFail("Only checking backward alternatives must not replace checking zero")
        }
    }

    private func assertRejected(_ decision: ScrollRegistration.Decision,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .reject = decision else {
            return XCTFail("Unsafe overlap must be rejected", file: file, line: line)
        }
    }

    private func pixels(height: Int = 256, xOffset: Int = 0, yOffset: Int = 0,
                        period: Int? = nil) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(128 * height * 4)
        for y in 0..<height {
            let sourceY = period.map { (y + yOffset) % $0 } ?? (y + yOffset)
            for x in 0..<128 {
                var value = UInt32((x + xOffset) / 8 + 1) &* 0x9e3779b9
                value ^= UInt32(sourceY / 8 + 1) &* 0x85ebca6b
                value ^= value >> 16
                value = value &* 0xc2b2ae35
                value ^= value >> 13
                result.append(UInt8(truncatingIfNeeded: value))
                result.append(UInt8(truncatingIfNeeded: value >> 8))
                result.append(UInt8(truncatingIfNeeded: value >> 16))
                result.append(255)
            }
        }
        return result
    }

    private func image(_ pixels: [UInt8], height: Int = 256) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width: 128, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 128 * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }
}
