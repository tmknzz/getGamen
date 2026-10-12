import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes indexed PNG using ImageIO, with optional per-entry transparency.
/// Palette generation is separate from this lossless palette/index container.
public enum IndexedPNG {
    public enum EncodingError: Error, Equatable {
        case invalidDimensions, invalidPalette, invalidIndices, encodingFailed
    }

    public static func encode(width: Int, height: Int, indices: [UInt8], paletteRGB: [UInt8]) throws -> Data {
        try write(width: width, height: height, indices: indices, paletteRGB: paletteRGB, alpha: nil)
    }

    /// Distinct entries may have identical RGB but different alpha values.
    public static func encode(width: Int, height: Int, indices: [UInt8], paletteRGBA: [UInt8]) throws -> Data {
        guard !paletteRGBA.isEmpty, paletteRGBA.count.isMultiple(of: 4), paletteRGBA.count <= 1024 else {
            throw EncodingError.invalidPalette
        }
        var rgb: [UInt8] = []
        var alpha: [UInt8] = []
        rgb.reserveCapacity(paletteRGBA.count / 4 * 3)
        alpha.reserveCapacity(paletteRGBA.count / 4)
        for offset in stride(from: 0, to: paletteRGBA.count, by: 4) {
            rgb.append(contentsOf: paletteRGBA[offset..<(offset + 3)])
            alpha.append(paletteRGBA[offset + 3])
        }
        return try write(width: width, height: height, indices: indices, paletteRGB: rgb, alpha: alpha)
    }

    private static func write(width: Int, height: Int, indices: [UInt8],
                              paletteRGB: [UInt8], alpha: [UInt8]?) throws -> Data {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow else { throw EncodingError.invalidDimensions }
        guard !paletteRGB.isEmpty, paletteRGB.count.isMultiple(of: 3), paletteRGB.count <= 768 else {
            throw EncodingError.invalidPalette
        }
        let colors = paletteRGB.count / 3
        guard indices.count == pixelCount, indices.allSatisfy({ Int($0) < colors }) else {
            throw EncodingError.invalidIndices
        }
        guard let base = CGColorSpace(name: CGColorSpace.sRGB),
              let colorSpace = paletteRGB.withUnsafeBufferPointer({ palette -> CGColorSpace? in
                  guard let address = palette.baseAddress else { return nil }
                  return CGColorSpace(indexedBaseSpace: base, last: colors - 1, colorTable: address)
              }),
              let provider = CGDataProvider(data: Data(indices) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: width, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw EncodingError.encodingFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw EncodingError.encodingFailed
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue
        ]
        if let alpha, alpha.contains(where: { $0 != 255 }) {
            // Public ImageIO option: one tRNS alpha byte for each palette entry.
            properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGTransparency: Data(alpha) as CFData] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw EncodingError.encodingFailed
        }
        return output as Data
    }
}
