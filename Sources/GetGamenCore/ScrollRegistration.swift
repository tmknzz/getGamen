import CoreGraphics
import Vision

/// Conservative pairwise registration. A rejected frame never becomes an append candidate.
public enum ScrollRegistration {
    public struct Match {
        public let appendedHeight: Int
        public let overlapHeight: Int
        public let rawTranslation: CGAffineTransform
        public let meanResidual: Double
    }

    public enum Rejection: Equatable, Sendable {
        case dimensions, rendering, registration, horizontal, backward, unreliable, ambiguous
    }

    public enum Decision {
        case append(Match)
        case unchanged
        case reject(Rejection)
    }

    public static func translation(previous: CGImage, current: CGImage) throws -> CGAffineTransform {
        guard previous.width == current.width, previous.height == current.height,
              previous.width > 0, previous.height > 0 else { throw RegistrationFailure.invalidInput }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current, orientation: .up)
        let handler = VNImageRequestHandler(cgImage: previous, orientation: .up)
        try handler.perform([request])
        guard let result = request.results?.first else { throw RegistrationFailure.noObservation }
        return result.alignmentTransform
    }

    public static func match(previous: CGImage, current: CGImage) -> Decision {
        guard previous.width == current.width, previous.height == current.height else { return .reject(.dimensions) }
        guard let before = Pixels(previous), let after = Pixels(current) else { return .reject(.rendering) }
        if before.bytes == after.bytes { return .unchanged }
        let transform: CGAffineTransform
        do { transform = try translation(previous: previous, current: current) }
        catch { return .reject(.registration) }
        return validate(before: before, after: after, translation: transform)
    }

    /// Deterministic validation entry point for testing a proposed translation independently of Vision.
    static func validate(previous: CGImage, current: CGImage, translation: CGAffineTransform) -> Decision {
        guard previous.width == current.width, previous.height == current.height else { return .reject(.dimensions) }
        guard let before = Pixels(previous), let after = Pixels(current) else { return .reject(.rendering) }
        if before.bytes == after.bytes { return .unchanged }
        return validate(before: before, after: after, translation: translation)
    }

    private static func validate(before: Pixels, after: Pixels, translation transform: CGAffineTransform) -> Decision {
        guard transform.tx.isFinite, transform.ty.isFinite else { return .reject(.registration) }
        guard abs(transform.tx) <= 1 else { return .reject(.horizontal) }

        // Vision maps the current image onto the previous image in its y-up space.
        // In top-row-first image buffers a forward scroll therefore has d = -ty.
        let displacement = -transform.ty
        guard displacement > 0 else { return .reject(.backward) }
        let minimumOverlap = max(32, (before.height + 3) / 4)
        let maximumDisplacement = before.height - minimumOverlap
        guard maximumDisplacement >= 1,
              displacement <= Double(maximumDisplacement) + 2 else {
            return .reject(.unreliable)
        }
        let center = Int(displacement.rounded())
        let lower = max(1, center - 2)
        let upper = min(maximumDisplacement, center + 2)
        guard lower <= upper else { return .reject(.unreliable) }

        // Shared across candidate refinement and the complete ambiguity scan.
        // Pixels bounds frame size, so this multiplication cannot overflow.
        var budget = WorkBudget(remaining: 8 * before.width * before.height)
        do {
            var accepted: [(offset: Int, residual: Double)] = []
            for offset in lower...upper {
                if let residual = try overlapResidual(before, after, offset: offset, budget: &budget) {
                    accepted.append((offset, residual))
                }
            }
            guard let best = accepted.min(by: { $0.residual < $1.residual }) else {
                return .reject(.unreliable)
            }
            // Challenge forward motion itself: stationary or backward alternatives
            // can explain a periodic frame just as well as Vision's proposal.
            for offset in (-maximumDisplacement)...maximumDisplacement where offset != best.offset {
                if try samplesAgree(before, after, offset: offset, budget: &budget),
                   try overlapResidual(before, after, offset: offset, budget: &budget) != nil {
                    return .reject(.ambiguous)
                }
            }
            return .append(Match(appendedHeight: best.offset,
                                 overlapHeight: before.height - best.offset,
                                 rawTranslation: transform, meanResidual: best.residual))
        } catch {
            // An incomplete ambiguity scan is not evidence of a safe join.
            return .reject(.unreliable)
        }
    }

    public enum RegistrationFailure: Error, Equatable { case noObservation, invalidInput }

    private struct WorkBudget {
        enum Failure: Error { case exhausted }
        var remaining: Int

        mutating func consumePixel() throws {
            guard remaining > 0 else { throw Failure.exhausted }
            remaining -= 1
        }
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            // Bound a single probe frame to 64 million pixels before allocation and multiplication.
            guard width > 0, height > 0, width <= 64_000_000 / height else { return nil }
            let rowBytes = width * 4
            var storage = [UInt8](repeating: 255, count: rowBytes * height)
            let rendered = storage.withUnsafeMutableBytes { buffer -> Bool in
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: rowBytes,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { return nil }
            self.width = width
            self.height = height
            bytes = storage
        }
    }

    /// Exact, strict validation: no differing label can disappear inside a whole-image average.
    private static func overlapResidual(_ before: Pixels, _ after: Pixels, offset: Int,
                                        budget: inout WorkBudget) throws -> Double? {
        let rows = before.height - abs(offset)
        let rowBytes = before.width * 4
        var total = 0.0
        var texturedRows = 0
        for y in 0..<rows {
            let previousRow = (y + max(0, offset)) * rowBytes
            let currentRow = (y + max(0, -offset)) * rowBytes
            var rowMinimum = 255
            var rowMaximum = 0
            for x in 0..<before.width {
                try budget.consumePixel()
                let source = previousRow + x * 4
                let target = currentRow + x * 4
                for channel in 0..<3 {
                    let value = Int(before.bytes[source + channel])
                    let delta = abs(value - Int(after.bytes[target + channel]))
                    guard delta <= 3 else { return nil }
                    total += Double(delta)
                }
                let luminance = (Int(before.bytes[source]) * 54
                    + Int(before.bytes[source + 1]) * 183
                    + Int(before.bytes[source + 2]) * 19) / 256
                rowMinimum = min(rowMinimum, luminance)
                rowMaximum = max(rowMaximum, luminance)
            }
            if rowMaximum - rowMinimum >= 16 { texturedRows += 1 }
        }
        guard texturedRows >= max(8, rows / 8) else { return nil }
        return total / Double(rows * before.width * 3)
    }

    private static func samplesAgree(_ before: Pixels, _ after: Pixels, offset: Int,
                                     budget: inout WorkBudget) throws -> Bool {
        let rows = before.height - abs(offset)
        for y in stride(from: 0, to: rows, by: max(1, rows / 16)) {
            for x in stride(from: 0, to: before.width, by: max(1, before.width / 16)) {
                try budget.consumePixel()
                let source = ((y + max(0, offset)) * before.width + x) * 4
                let target = ((y + max(0, -offset)) * before.width + x) * 4
                for channel in 0..<3 {
                    if abs(Int(before.bytes[source + channel]) - Int(after.bytes[target + channel])) > 3 {
                        return false
                    }
                }
            }
        }
        return true
    }
}
