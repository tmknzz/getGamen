import CoreFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Decodes immutable source bytes into upright, premultiplied 8-bit sRGB pixels.
/// This SDR normalization does not preserve HDR precision or rewrite source metadata.
public enum RasterImageDecoder {
    public enum DecodingError: LocalizedError, Equatable {
        case invalidData
        case unsupportedImageCount(Int)
        case invalidOrientation
        case invalidDimensions
        case decodingFailed
        case fileTooLarge

        public var errorDescription: String? {
            self == .fileTooLarge ? "画像ファイルのサイズが上限を超えています。" : nil
        }
    }

    public static func decode(_ data: Data) throws -> CGImage {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil else {
            throw DecodingError.invalidData
        }
        let count = CGImageSourceGetCount(source)
        guard count == 1 else { throw DecodingError.unsupportedImageCount(count) }
        try TIFFSourceValidator.validateIfTIFF(data)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        guard let w = properties?[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = properties?[kCGImagePropertyPixelHeight] as? NSNumber,
              let width = Int(exactly: w.doubleValue),
              let height = Int(exactly: h.doubleValue) else {
            throw DecodingError.invalidDimensions
        }
        try validateDimensions(width: width, height: height)
        let orientation = try validatedOrientation(properties?[kCGImagePropertyOrientation])
        // Default ImageIO images can defer decompression until rendering. Force it
        // here so a lazy handle is not mistaken for a successfully decoded raster.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true
        ]
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw DecodingError.decodingFailed
        }
        try validateDimensions(width: raw.width, height: raw.height)

        // A cached ImageIO handle can still lack usable raster data. Obtain the
        // complete native storage and consume that same copy in the transform.
        let (rowBits, rowOverflow) = raw.width.multipliedReportingOverflow(by: raw.bitsPerPixel)
        let (storageSize, storageOverflow) = raw.bytesPerRow.multipliedReportingOverflow(by: raw.height)
        guard raw.bitsPerPixel > 0, !rowOverflow, !storageOverflow, storageSize > 0,
              raw.bytesPerRow >= rowBits / 8 + (rowBits % 8 == 0 ? 0 : 1) else {
            throw DecodingError.invalidDimensions
        }
        guard let provider = raw.dataProvider, let storage = provider.data,
              CFDataGetLength(storage) >= storageSize,
              let copiedProvider = CGDataProvider(data: storage),
              let rawColorSpace = raw.colorSpace,
              let materialized = CGImage(width: raw.width, height: raw.height,
                                         bitsPerComponent: raw.bitsPerComponent,
                                         bitsPerPixel: raw.bitsPerPixel, bytesPerRow: raw.bytesPerRow,
                                         space: rawColorSpace, bitmapInfo: raw.bitmapInfo,
                                         provider: copiedProvider, decode: raw.decode,
                                         shouldInterpolate: raw.shouldInterpolate,
                                         intent: raw.renderingIntent),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw DecodingError.decodingFailed
        }

        // CGImage supplies raw pixels; original orientation metadata is not re-read by Core Image.
        let upright = CIImage(cgImage: materialized).oriented(forExifOrientation: orientation)
        let extent = upright.extent
        let expectedWidth = orientation >= 5 ? raw.height : raw.width
        let expectedHeight = orientation >= 5 ? raw.width : raw.height
        guard !extent.isNull, !extent.isInfinite,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0,
              extent.maxX.isFinite, extent.maxY.isFinite,
              extent.origin.x.rounded(.towardZero) == extent.origin.x,
              extent.origin.y.rounded(.towardZero) == extent.origin.y,
              extent.maxX.rounded(.towardZero) == extent.maxX,
              extent.maxY.rounded(.towardZero) == extent.maxY,
              let width = Int(exactly: extent.width),
              let height = Int(exactly: extent.height),
              width == expectedWidth, height == expectedHeight else {
            throw DecodingError.invalidDimensions
        }
        try validateDimensions(width: width, height: height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DecodingError.decodingFailed
        }
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .outputPremultiplied: true
        ])
        guard let result = context.createCGImage(upright, from: extent,
                                                format: .RGBA8, colorSpace: colorSpace) else {
            throw DecodingError.decodingFailed
        }
        guard result.width == expectedWidth, result.height == expectedHeight else {
            throw DecodingError.invalidDimensions
        }
        try validateDimensions(width: result.width, height: result.height)
        return result
    }

    /// Absence means up; present malformed metadata must never silently become up.
    static func validatedOrientation(_ value: Any?) throws -> Int32 {
        guard let value else { return 1 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              let orientation = Int32(exactly: number.doubleValue),
              (1...8).contains(orientation),
              number.decimalValue == Decimal(Int(orientation)) else {
            throw DecodingError.invalidOrientation
        }
        return orientation
    }

    /// Default file size limit: 64M pixels × 8 bytes for 16-bit RGBA.
    public static let maxFileBytes = 512_000_000

    public static func readFile(_ url: URL) throws -> Data {
        try readFile(url, limit: maxFileBytes)
    }

    static func readFile(_ url: URL, limit: Int) throws -> Data {
        precondition(limit >= 0 && limit < Int.max)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DecodingError.fileTooLarge }
        return data
    }

    /// Bound each RGBA raster to 256 MB before ImageIO expands compressed input.
    /// Editing needs several rasters, so accepting unbounded dimensions can exhaust memory.
    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw DecodingError.invalidDimensions }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sizeOverflow, rowBytes > 0, byteCount > 0 else {
            throw DecodingError.invalidDimensions
        }
        guard byteCount <= 256_000_000 else { throw DecodingError.invalidDimensions }
    }
}
