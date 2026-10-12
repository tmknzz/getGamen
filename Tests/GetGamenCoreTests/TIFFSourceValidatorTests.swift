import Foundation
import XCTest
@testable import GetGamenCore

final class TIFFSourceValidatorTests: XCTestCase {
    func testClassicAndBigTIFFBothByteOrdersValidateOriginalRanges() throws {
        for big in [false, true] {
            for little in [false, true] {
                let full = fixture(big: big, little: little)
                XCTAssertNoThrow(try TIFFSourceValidator.validateIfTIFF(full))
                XCTAssertThrowsError(try TIFFSourceValidator.validateIfTIFF(full.dropLast()))
                var cycle = full
                let next = big ? 16 + 8 + 40 : 8 + 2 + 24
                write(big ? 16 : 8, width: big ? 8 : 4, into: &cycle, offset: next, little: little)
                XCTAssertThrowsError(try TIFFSourceValidator.validateIfTIFF(cycle))
            }
        }
    }

    func testTileAndStripSecondRangesCannotHideTruncation() throws {
        for tile in [false, true] {
            let data = fixture(big: false, little: true, tile: tile, multiple: true)
            XCTAssertNoThrow(try TIFFSourceValidator.validateIfTIFF(data))
            for missing in 1...4 {
                XCTAssertThrowsError(try TIFFSourceValidator.validateIfTIFF(data.dropLast(missing)))
            }
        }
    }

    func testMalformedExternalArrayAndOverflowRejectBeforeAllocation() throws {
        var data = fixture(big: true, little: true)
        write(UInt64.max, width: 8, into: &data, offset: 16, little: true)
        XCTAssertThrowsError(try TIFFSourceValidator.validateIfTIFF(data))
        data = fixture(big: true, little: true)
        write(UInt64.max, width: 8, into: &data, offset: 28, little: true)
        XCTAssertThrowsError(try TIFFSourceValidator.validateIfTIFF(data))
        data = fixture(big: false, little: true, multiple: true)
        write(UInt64(data.count), width: 4, into: &data, offset: 18, little: true)
        XCTAssertThrowsError(try TIFFSourceValidator.validateIfTIFF(data))
    }

    private func fixture(big: Bool, little: Bool, tile: Bool = false, multiple: Bool = false) -> Data {
        let word = big ? 8 : 4, entry = big ? 20 : 12, header = big ? 16 : 8, countWidth = big ? 8 : 2
        let arrayStart = header + countWidth + entry * 2 + word
        let count = multiple ? 2 : 1
        let pixelStart = arrayStart + (multiple ? count * word * 2 : 0)
        var bytes = Data(repeating: 0, count: pixelStart + count * 4)
        bytes[0] = little ? 0x49 : 0x4d; bytes[1] = bytes[0]
        write(big ? 43 : 42, width: 2, into: &bytes, offset: 2, little: little)
        if big { write(8, width: 2, into: &bytes, offset: 4, little: little) }
        write(UInt64(header), width: word, into: &bytes, offset: big ? 8 : 4, little: little)
        write(2, width: countWidth, into: &bytes, offset: header, little: little)
        for i in 0..<2 {
            let start = header + countWidth + i * entry
            write(UInt64((tile ? 324 : 273) + (i == 0 ? 0 : (tile ? 1 : 6))), width: 2, into: &bytes, offset: start, little: little)
            write(big ? 16 : 4, width: 2, into: &bytes, offset: start + 2, little: little)
            write(UInt64(count), width: word, into: &bytes, offset: start + 4, little: little)
            let value = multiple ? arrayStart + i * count * word : (i == 0 ? pixelStart : 4)
            write(UInt64(value), width: word, into: &bytes, offset: start + (big ? 12 : 8), little: little)
            if multiple {
                for j in 0..<count {
                    write(UInt64(i == 0 ? pixelStart + j * 4 : 4), width: word,
                          into: &bytes, offset: value + j * word, little: little)
                }
            }
        }
        return bytes
    }

    private func write(_ value: UInt64, width: Int, into bytes: inout Data, offset: Int, little: Bool) {
        for index in 0..<width {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((little ? index : width - 1 - index) * 8))
        }
    }
}
