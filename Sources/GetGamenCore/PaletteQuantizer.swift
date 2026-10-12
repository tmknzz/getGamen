/// Deterministic, adaptive palette selection for unpremultiplied sRGB RGBA bytes.
/// PNG encoding remains the responsibility of the Apple image frameworks.
public enum PaletteQuantizer {
    public struct Result: Equatable {
        public let paletteRGBA: [UInt8]
        public let indices: [UInt8]
    }

    public enum QuantizationError: Error, Equatable {
        case invalidPixels
    }

    private struct Color {
        let packed: UInt32
        let count: Int

        func component(_ channel: Int) -> UInt8 {
            UInt8(truncatingIfNeeded: packed >> (channel * 8))
        }
    }

    private struct Bucket {
        let colors: [Color]
        let weight: Int
        let splitChannel: Int
        let score: Double

        init(_ colors: [Color]) {
            self.colors = colors
            var minimum = [UInt8](repeating: 255, count: 4)
            var maximum = [UInt8](repeating: 0, count: 4)
            var total = 0
            for color in colors {
                // Counts belong to disjoint pixels, so their sum fits in Int.
                total += color.count
                for channel in 0..<4 {
                    minimum[channel] = min(minimum[channel], color.component(channel))
                    maximum[channel] = max(maximum[channel], color.component(channel))
                }
            }
            weight = total
            var channel = 0
            for candidate in 1..<4 {
                if Int(maximum[candidate]) - Int(minimum[candidate]) >
                    Int(maximum[channel]) - Int(minimum[channel]) {
                    channel = candidate
                }
            }
            splitChannel = channel
            score = colors.count > 1
                ? Double(total) * Double(Int(maximum[channel]) - Int(minimum[channel]))
                : 0
        }

        func split() -> (Bucket, Bucket) {
            let sorted = colors.sorted {
                let left = $0.component(splitChannel)
                let right = $1.component(splitChannel)
                return left == right ? $0.packed < $1.packed : left < right
            }
            var accumulated = 0
            var boundary = 1
            for index in 0..<(sorted.count - 1) {
                accumulated += sorted[index].count
                boundary = index + 1
                if accumulated >= weight / 2 + weight % 2 { break }
            }
            return (Bucket(Array(sorted[..<boundary])), Bucket(Array(sorted[boundary...])))
        }

        func representative() -> [UInt8] {
            (0..<4).map { channel in
                // Floating-point accumulation avoids count * component integer overflow.
                let sum = colors.reduce(0.0) {
                    $0 + Double($1.component(channel)) * Double($1.count)
                }
                return UInt8(min(255, max(0, (sum / Double(weight)).rounded())))
            }
        }
    }

    private static func packedColor(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Preserves every RGBA value exactly when there are at most 256 distinct colors.
    /// Otherwise uses frequency-weighted median cuts, including alpha as a channel.
    /// Fully transparent, partially transparent, and opaque pixels never share a
    /// bucket; partial alpha and color values may be approximated within their group.
    /// In lossy mode, fully transparent colors use one entry to reserve visible colors.
    /// Working storage is proportional to the distinct-color count and output size.
    public static func quantize(rgba: [UInt8]) throws -> Result {
        guard !rgba.isEmpty, rgba.count.isMultiple(of: 4) else {
            throw QuantizationError.invalidPixels
        }
        var histogram: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            histogram[packedColor(rgba, at: offset), default: 0] += 1
        }
        let colors = histogram.map { Color(packed: $0.key, count: $0.value) }
            .sorted { $0.packed < $1.packed }
        // Release the count table before allocating the color-to-index lookup.
        histogram.removeAll(keepingCapacity: false)
        var buckets: [Bucket]
        if colors.count <= 256 {
            buckets = colors.map { Bucket([$0]) }
        } else {
            // Keep opaque masks opaque and preserve the transparency classes.
            let transparent = colors.filter { $0.component(3) == 0 }
            let partial = colors.filter { $0.component(3) > 0 && $0.component(3) < 255 }
            let opaque = colors.filter { $0.component(3) == 255 }
            buckets = [transparent, partial, opaque].filter { !$0.isEmpty }.map(Bucket.init)
            while buckets.count < 256 {
                var selected: Int?
                for index in buckets.indices where buckets[index].colors.count > 1 &&
                    buckets[index].colors[0].component(3) != 0 {
                    if let current = selected {
                        if buckets[index].score > buckets[current].score { selected = index }
                    } else {
                        selected = index
                    }
                }
                guard let selected else { break }
                let (left, right) = buckets[selected].split()
                buckets[selected] = left
                buckets.append(right)
            }
        }
        var palette: [UInt8] = []
        palette.reserveCapacity(buckets.count * 4)
        var lookup: [UInt32: UInt8] = [:]
        lookup.reserveCapacity(colors.count)
        for (index, bucket) in buckets.enumerated() {
            palette.append(contentsOf: bucket.representative())
            for color in bucket.colors { lookup[color.packed] = UInt8(index) }
        }
        var indices: [UInt8] = []
        indices.reserveCapacity(rgba.count / 4)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            guard let index = lookup[packedColor(rgba, at: offset)] else {
                throw QuantizationError.invalidPixels
            }
            indices.append(index)
        }
        return Result(paletteRGBA: palette, indices: indices)
    }
}
