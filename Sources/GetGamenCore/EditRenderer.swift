import CoreGraphics
import Foundation

/// The shared preview/export boundary. Unsupported edits fail before drawing any output.
public enum EditRenderer {
    public enum Feature: String, Equatable, Sendable {
        case outline, grayMask, mosaic, crop
    }

    public enum RenderingError: Error, Equatable {
        case invalidImage
        case pixelSizeMismatch
        case unsupportedFeature(Feature)
        case renderingFailed
    }

    /// Accepts upright pixels; source-file orientation belongs to RasterImageDecoder.
    public static func render(original: CGImage, edits: EditState) throws -> CGImage {
        let width = original.width
        let height = original.height
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !rowOverflow, !sizeOverflow,
              rowBytes > 0, byteCount > 0, !original.isMask,
              original.colorSpace != nil else {
            throw RenderingError.invalidImage
        }
        // Validate the entire snapshot first, including later objects and crop.
        try edits.validate(pixelSize: PixelSize(width: width, height: height))

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                        CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderingError.renderingFailed
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Redact before any neighborhood sampling, then reapply masks last.
        // Thus hidden source pixels cannot leak through a mosaic outside a mask.
        func maskPass() {
            for object in edits.objects {
                let color: RGBColor
                switch object.style {
                case .grayMask(let brightness): color = RGBColor(red: brightness, green: brightness, blue: brightness)
                case .colorMask(let value): color = value
                default: continue
                }
                let rect = coverage(object.bounds, height: height)
                func channel(_ value: Double) -> CGFloat { CGFloat((value * 255).rounded()) / 255 }
                context.saveGState()
                context.setShouldAntialias(false)
                context.setBlendMode(.copy)
                context.setFillColor(red: channel(color.red), green: channel(color.green), blue: channel(color.blue), alpha: 1)
                context.fill(rect)
                context.restoreGState()
            }
        }
        maskPass()
        guard let redacted = context.makeImage() else { throw RenderingError.renderingFailed }
        // Keep only the most recent size, rather than one full raster per size.
        var cachedMosaic: (size: Int, image: CGImage)?
        for object in edits.objects {
            context.saveGState()
            context.setBlendMode(.normal)
            switch object.style {
            case .grayMask, .colorMask: break
            case .outline(let style):
                let b = object.bounds
                let rect = CGRect(x: b.x, y: Double(height) - b.y - b.height, width: b.width, height: b.height)
                let path: CGPath
                switch style.shape {
                case .rectangle: path = CGPath(rect: rect, transform: nil)
                case .roundedRectangle:
                    path = CGPath(roundedRect: rect, cornerWidth: style.cornerRadius,
                                  cornerHeight: style.cornerRadius, transform: nil)
                case .circle, .ellipse: path = CGPath(ellipseIn: rect, transform: nil)
                }
                context.setShouldAntialias(true)
                context.addPath(path)
                context.clip()
                context.addPath(path)
                context.setStrokeColor(red: style.color.red, green: style.color.green, blue: style.color.blue, alpha: 1)
                context.setLineWidth(min(style.lineWidth, max(b.width, b.height)) * 2)
                context.setLineJoin(.miter)
                context.setLineCap(.butt)
                context.strokePath()
            case .mosaic(let blockSize):
                let mosaic: CGImage
                if let cached = cachedMosaic, cached.size == blockSize { mosaic = cached.image }
                else {
                    guard let image = blockAverage(redacted, blockSize: blockSize, space: space) else {
                        context.restoreGState()
                        throw RenderingError.renderingFailed
                    }
                    mosaic = image
                    cachedMosaic = (blockSize, image)
                }
                context.setShouldAntialias(false)
                context.clip(to: coverage(object.bounds, height: height))
                context.setBlendMode(.copy)
                context.draw(mosaic, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            context.restoreGState()
        }
        maskPass()
        if let border = edits.border {
            let crop = edits.crop ?? PixelCrop(x: 0, y: 0, width: width, height: height)
            let rect = CGRect(x: crop.x, y: height - crop.y - crop.height, width: crop.width, height: crop.height)
            let thickness = min(CGFloat(border.width), min(rect.width, rect.height))
            let color = border.resolvedColor
            context.setShouldAntialias(false)
            context.setBlendMode(.copy)
            context.setFillColor(red: CGFloat((color.red * 255).rounded()) / 255,
                                 green: CGFloat((color.green * 255).rounded()) / 255,
                                 blue: CGFloat((color.blue * 255).rounded()) / 255, alpha: 1)
            context.fill([
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness),
                CGRect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness),
                CGRect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height),
                CGRect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height)
            ])
        }
        guard let result = context.makeImage(), result.width == width, result.height == height else {
            throw RenderingError.renderingFailed
        }
        if let crop = edits.crop {
            guard let cropped = result.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)),
                  cropped.width == crop.width, cropped.height == crop.height else { throw RenderingError.renderingFailed }
            return cropped
        }
        return result
    }

    private static func coverage(_ bounds: PixelBounds, height: Int) -> CGRect {
        let x = floor(bounds.x), y = floor(bounds.y)
        let right = ceil(bounds.x + bounds.width), bottom = ceil(bounds.y + bounds.height)
        return CGRect(x: x, y: Double(height) - bottom, width: right - x, height: bottom - y)
    }

    /// Fills each blockSize cell, anchored at the top-left pixel, with the mean of its pixels.
    /// A point sample per cell (CIPixellate) turns thin text into scattered dark dots.
    private static func blockAverage(_ image: CGImage, blockSize: Int, space: CGColorSpace) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                        CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rowBytes = context.bytesPerRow
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for top in stride(from: 0, to: height, by: blockSize) {
            let rows = top..<min(top + blockSize, height)
            for left in stride(from: 0, to: width, by: blockSize) {
                let columns = left..<min(left + blockSize, width)
                var sum = SIMD4<Int>.zero
                for y in rows { for x in columns {
                    let i = y * rowBytes + x * 4
                    sum &+= SIMD4(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
                } }
                let count = rows.count * columns.count
                let mean = (sum &+ count / 2) / count
                for y in rows { for x in columns {
                    let i = y * rowBytes + x * 4
                    for c in 0..<4 { pixels[i + c] = UInt8(mean[c]) }
                } }
            }
        }
        return context.makeImage()
    }

    /// Stored geometry describes upright original pixels. It never requests a resize.
    public static func render(originalData: Data, pixelSize: PixelSize,
                              edits: EditState) throws -> CGImage {
        try pixelSize.validate()
        let original = try RasterImageDecoder.decode(originalData)
        guard original.width == pixelSize.width, original.height == pixelSize.height else {
            throw RenderingError.pixelSizeMismatch
        }
        return try render(original: original, edits: edits)
    }
}
