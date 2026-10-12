import Foundation
import CoreGraphics

/// Each accepted frame is durably checkpointed before replacing the last matching anchor.
public actor ScrollAccumulator {
    public enum Outcome: Equatable, Sendable {
        case started, appended(Int), unchanged, rejected(ScrollRegistration.Rejection)
    }
    public struct Snapshot: Sendable {
        public let png: Data
        public let width: Int
        public let height: Int
        public let frames: Int
    }
    private struct Checkpoint: Codable {
        let version: Int
        let composite: Data
        let lastFrame: Data
        let frames: Int
    }
    private let checkpointURL: URL
    private var composite: CGImage?
    private var lastFrame: CGImage?
    private var frameCount = 0
    private var compositePNG: Data?

    public init(checkpointURL: URL) { self.checkpointURL = checkpointURL }

    public func restore() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return nil }
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
        guard checkpoint.version == 1, checkpoint.frames > 0 else { throw RasterImageDecoder.DecodingError.invalidData }
        let image = try RasterImageDecoder.decode(checkpoint.composite)
        let anchor = try RasterImageDecoder.decode(checkpoint.lastFrame)
        guard image.width == anchor.width, image.height >= anchor.height, checkpoint.frames <= image.height else { throw RasterImageDecoder.DecodingError.invalidDimensions }
        composite = image; compositePNG = checkpoint.composite; lastFrame = anchor; frameCount = checkpoint.frames
        return Snapshot(png: checkpoint.composite, width: image.width, height: image.height, frames: frameCount)
    }

    public func accept(_ image: CGImage) throws -> Outcome {
        let next: CGImage
        let outcome: Outcome
        if let previous = lastFrame, let joined = composite {
            switch ScrollRegistration.match(previous: previous, current: image) {
            case .unchanged: return .unchanged
            case .reject(let reason): return .rejected(reason)
            case .append(let match):
                next = try Self.append(joined, current: image, height: match.appendedHeight)
                outcome = .appended(match.appendedHeight)
            }
        } else { next = image; outcome = .started }
        let checkpoint = Checkpoint(version: 1, composite: try RasterImageCodec.encode(next, format: .png),
                                    lastFrame: try RasterImageCodec.encode(image, format: .png), frames: frameCount + 1)
        try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
        composite = next; compositePNG = checkpoint.composite; lastFrame = image; frameCount = checkpoint.frames
        return outcome
    }

    public func snapshot() throws -> Snapshot? {
        guard let composite, let compositePNG else { return nil }
        return Snapshot(png: compositePNG,
                        width: composite.width, height: composite.height, frames: frameCount)
    }

    /// Called only once the composite has been published as an immutable history original.
    public func clear() throws {
        if FileManager.default.fileExists(atPath: checkpointURL.path) { try FileManager.default.removeItem(at: checkpointURL) }
        composite = nil; compositePNG = nil; lastFrame = nil; frameCount = 0
    }

    static func append(_ composite: CGImage, current: CGImage, height: Int) throws -> CGImage {
        guard composite.width == current.width, height > 0, height < current.height else {
            throw RasterImageDecoder.DecodingError.invalidDimensions
        }
        let (totalHeight, overflow) = composite.height.addingReportingOverflow(height)
        guard !overflow else { throw RasterImageDecoder.DecodingError.invalidDimensions }
        try RasterImageDecoder.validateDimensions(width: composite.width, height: totalHeight)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: composite.width, height: totalHeight,
                                      bitsPerComponent: 8, bytesPerRow: composite.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let tail = current.cropping(to: CGRect(x: 0, y: current.height - height, width: current.width, height: height)) else {
            throw RasterImageCodec.EncodingError.encodingFailed
        }
        context.interpolationQuality = .none; context.setBlendMode(.copy)
        // Quartz destinations are y-up; CGImage cropping is top-left.
        context.draw(composite, in: CGRect(x: 0, y: height, width: composite.width, height: composite.height))
        context.draw(tail, in: CGRect(x: 0, y: 0, width: current.width, height: height))
        guard let result = context.makeImage() else { throw RasterImageCodec.EncodingError.encodingFailed }
        return result
    }
}
