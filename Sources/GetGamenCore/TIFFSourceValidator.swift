import Foundation

/// ImageIO may synthesize a full raster for truncated TIFF strips. Validate the
/// original storage references before treating its decoded buffer as evidence.
enum TIFFSourceValidator {
    static func validateIfTIFF(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }
        let little: Bool
        if bytes[0...1] == [0x49, 0x49] { little = true }
        else if bytes[0...1] == [0x4d, 0x4d] { little = false }
        else { return }
        let parser = Parser(bytes: bytes, little: little)
        let version = try parser.read(2, 2)
        guard version == 42 || version == 43 else { return }
        try parser.validate(big: version == 43)
    }

    private struct Parser {
        let bytes: [UInt8]
        let little: Bool
        var failure: RasterImageDecoder.DecodingError { .decodingFailed }

        func range(_ offset: UInt64, _ length: UInt64) throws -> Int {
            guard offset <= UInt64(bytes.count), length <= UInt64(bytes.count) - offset,
                  let start = Int(exactly: offset) else { throw failure }
            return start
        }
        func read(_ offset: UInt64, _ width: Int) throws -> UInt64 {
            let start = try range(offset, UInt64(width))
            var value: UInt64 = 0
            for index in 0..<width {
                let position = little ? width - 1 - index : index
                value = (value << 8) | UInt64(bytes[start + position])
            }
            return value
        }
        func product(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
            let value = a.multipliedReportingOverflow(by: b)
            guard !value.overflow else { throw failure }
            return value.partialValue
        }

        func validate(big: Bool) throws {
            let word = big ? 8 : 4
            let countWidth = big ? 8 : 2
            let entryWidth: UInt64 = big ? 20 : 12
            if big {
                guard try read(4, 2) == 8, try read(6, 2) == 0 else { throw failure }
            }
            var directory = try read(big ? 8 : 4, word)
            guard directory != 0 else { throw failure }
            var seen = Set<UInt64>()
            while directory != 0 {
                guard seen.insert(directory).inserted else { throw failure }
                let count = try read(directory, countWidth)
                let table = directory + UInt64(countWidth) // validated read proves this addition safe
                let tableBytes = try product(count, entryWidth)
                _ = try range(table, tableBytes)
                var fields: [UInt64: [UInt64]] = [:]
                for index in 0..<count {
                    let entry = table + index * entryWidth
                    let tag = try read(entry, 2), type = try read(entry + 2, 2)
                    let elements = try read(entry + 4, word)
                    let unit: UInt64
                    switch type {
                    case 1, 2, 6, 7: unit = 1
                    case 3, 8: unit = 2
                    case 4, 9, 11, 13: unit = 4
                    case 5, 10, 12, 16, 17, 18: unit = 8
                    default: throw failure
                    }
                    let length = try product(elements, unit)
                    let inline = entry + (big ? 12 : 8)
                    let offset = try length > UInt64(word) ? read(inline, word) : inline
                    _ = try range(offset, length)
                    if [273, 279, 324, 325, 513, 514].contains(tag) {
                        guard fields[tag] == nil, [3, 4, 16].contains(type), elements > 0 else { throw failure }
                        fields[tag] = try (0..<elements).map { try read(offset + $0 * unit, Int(unit)) }
                    }
                }
                var hasRaster = false
                for (offsetTag, countTag): (UInt64, UInt64) in [(273, 279), (324, 325), (513, 514)] {
                    if fields[offsetTag] != nil || fields[countTag] != nil {
                        guard let offsets = fields[offsetTag], let lengths = fields[countTag],
                              offsets.count == lengths.count else { throw failure }
                        hasRaster = true
                        for (offset, length) in zip(offsets, lengths) {
                            guard offset > 0, length > 0 else { throw failure }
                            _ = try range(offset, length)
                        }
                    }
                }
                guard hasRaster else { throw failure }
                directory = try read(table + tableBytes, word)
            }
        }
    }
}
