import Foundation

public enum CaptureCountdownError: Error, Equatable {
    case invalidSeconds, invalidClock
}

/// Relative monotonic instants and absolute wake deadlines; internal deterministic test seam.
@MainActor
struct CaptureCountdownClock {
    let now: @MainActor () -> Duration
    let sleepUntil: @MainActor (Duration) async throws -> Void
}

/// Stateless timing only. The caller owns its capture token and cancellation scope.
@MainActor
public struct CaptureCountdown {
    private let clock: CaptureCountdownClock

    public init() {
        let continuous = ContinuousClock()
        let origin = continuous.now
        clock = CaptureCountdownClock(now: { origin.duration(to: continuous.now) }, sleepUntil: { deadline in
            try await continuous.sleep(until: origin.advanced(by: deadline), tolerance: .zero)
        })
    }

    init(clock: CaptureCountdownClock) { self.clock = clock }

    public func wait(seconds: Int, onRemaining: @MainActor (Int) -> Void) async throws {
        guard (0...12).contains(seconds) else { throw CaptureCountdownError.invalidSeconds }
        try Task.checkCancellation()
        if seconds == 0 {
            onRemaining(0)
            try Task.checkCancellation()
            return
        }

        let start = clock.now()
        let interval = Duration.seconds(seconds)
        let deadline = start + interval
        var previous = start
        var requiredWake: Duration?
        var lastEmitted = seconds
        onRemaining(seconds)
        try Task.checkCancellation()

        while true {
            let now = clock.now()
            guard now >= previous else { throw CaptureCountdownError.invalidClock }
            if let requiredWake, now < requiredWake {
                // A returned sleep must have reached its requested boundary.
                throw CaptureCountdownError.invalidClock
            }
            previous = now
            if now >= deadline {
                onRemaining(0)
                try Task.checkCancellation()
                return
            }
            let remainingDuration = deadline - now
            guard remainingDuration > .zero, remainingDuration <= interval else {
                throw CaptureCountdownError.invalidClock
            }
            let components = remainingDuration.components
            guard let wholeSeconds = Int(exactly: components.seconds) else {
                throw CaptureCountdownError.invalidClock
            }
            let remaining = wholeSeconds + (components.attoseconds > 0 ? 1 : 0)
            guard (1...seconds).contains(remaining) else { throw CaptureCountdownError.invalidClock }
            if remaining != lastEmitted {
                lastEmitted = remaining
                onRemaining(remaining)
                try Task.checkCancellation()
            }
            let nextWake = deadline - .seconds(remaining - 1)
            guard nextWake > now else { throw CaptureCountdownError.invalidClock }
            requiredWake = nextWake
            do { try await clock.sleepUntil(nextWake) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
            try Task.checkCancellation()
        }
    }
}
