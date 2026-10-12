import CoreGraphics

/// Composes already captured tiles; no screen capture or permission work occurs here.
enum RegionTileCompositor {
    static func compose(plan: RegionCapturePlan, images: [String: CGImage]) throws -> CGImage {
        let width = plan.outputSize.width
        let height = plan.outputSize.height
        guard width > 0, height > 0, plan.outputScale.isFinite, plan.outputScale > 0,
              !plan.tiles.isEmpty else { throw RegionCaptureError.invalidImage }
        let row = width.multipliedReportingOverflow(by: 4)
        guard !row.overflow, !row.partialValue.multipliedReportingOverflow(by: height).overflow else {
            throw RegionCaptureError.invalidImage
        }
        var identifiers = Set<String>()
        var destinations: [RegionPixelRect] = []
        for tile in plan.tiles {
            let rect = tile.destination
            guard !tile.displayID.isEmpty, identifiers.insert(tile.displayID).inserted,
                  tile.pixelSize.width > 0, tile.pixelSize.height > 0,
                  let image = images[tile.displayID], image.width == tile.pixelSize.width,
                  image.height == tile.pixelSize.height,
                  rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
                  rect.width <= width, rect.height <= height,
                  rect.x <= width - rect.width, rect.y <= height - rect.height else {
                throw RegionCaptureError.invalidImage
            }
            // Containment above makes endpoint additions safe. Shared edges are permitted.
            for previous in destinations {
                if rect.x < previous.x + previous.width && previous.x < rect.x + rect.width &&
                    rect.y < previous.y + previous.height && previous.y < rect.y + rect.height {
                    throw RegionCaptureError.invalidImage
                }
            }
            destinations.append(rect)
        }
        guard identifiers == Set(images.keys) else { throw RegionCaptureError.invalidImage }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: row.partialValue, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                        CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RegionCaptureError.compositionFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.copy)
        for tile in plan.tiles {
            guard let image = images[tile.displayID] else { throw RegionCaptureError.invalidImage }
            let rect = tile.destination
            // Plans use top-left pixels; the bitmap context uses a bottom-left drawing origin.
            let target = CGRect(x: rect.x, y: height - rect.y - rect.height,
                                width: rect.width, height: rect.height)
            context.saveGState()
            context.clip(to: target)
            context.interpolationQuality = image.width == rect.width && image.height == rect.height ? .none : .high
            context.draw(image, in: target)
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw RegionCaptureError.compositionFailed }
        return result
    }
}
