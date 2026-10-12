import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes an already-upright raster without modifying its source or writing files.
/// Source-file orientation normalization belongs to the import pipeline.
public enum RasterImageCodec {
    public enum Format: Sendable {
        case png
        case png8
        case jpeg(quality: Double)
    }

    public enum EncodingError: Error, Equatable {
        case invalidImage
        case invalidQuality
        case encodingFailed
    }

    /// PNG retains the supplied raster's alpha. JPEG composites alpha over white
    /// using ImageIO's documented default for formats that cannot represent alpha.
    /// JPEG quality must be finite and in 0...1; quality 1 is still lossy JPEG.
    /// No original EXIF/XMP/GPS metadata is copied. Orientation 1 describes the
    /// supplied pixels; it does not rotate incorrectly oriented input pixels.
    public static func encode(_ image: CGImage, format: Format) throws -> Data {
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard image.width > 0, image.height > 0, !overflow, pixelCount > 0 else {
            throw EncodingError.invalidImage
        }

        let type: UTType
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue
        ]
        switch format {
        case .png:
            type = .png
        case .png8:
            let rgba = try normalizedRGBA(image)
            let result = try PaletteQuantizer.quantize(rgba: rgba)
            return try IndexedPNG.encode(width: image.width, height: image.height,
                                         indices: result.indices, paletteRGBA: result.paletteRGBA)
        case .jpeg(let quality):
            guard quality.isFinite, (0...1).contains(quality) else {
                throw EncodingError.invalidQuality
            }
            type = .jpeg
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        ) else {
            throw EncodingError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw EncodingError.encodingFailed
        }
        return output as Data
    }

    /// Core Graphics normalizes color/profile and alpha storage before quantization.
    /// Low-alpha RGB can incur 8-bit rounding; hidden RGB at alpha zero is set to zero.
    /// Exact palette preservation refers to these normalized straight RGBA values.
    private static func normalizedRGBA(_ image: CGImage) throws -> [UInt8] {
        let (rowBytes, rowOverflow) = image.width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: image.height)
        guard !rowOverflow, !sizeOverflow, rowBytes > 0, byteCount > 0 else {
            throw EncodingError.invalidImage
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw EncodingError.encodingFailed
        }
        var rgba = [UInt8](repeating: 0, count: byteCount)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress,
                  let context = CGContext(data: address, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                            CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw EncodingError.encodingFailed
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[offset + 3])
            for channel in 0..<3 {
                rgba[offset + channel] = alpha == 0 ? 0 : UInt8(min(255,
                    (Int(rgba[offset + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return rgba
    }
}
