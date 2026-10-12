import Foundation
import CoreFoundation
import Observation

public struct CaptureSettingsSnapshot: Equatable, Sendable {
    public let timerSeconds: Int
    public let showsCursor: Bool

    public init(timerSeconds: Int, showsCursor: Bool) {
        self.timerSeconds = timerSeconds
        self.showsCursor = showsCursor
    }
}

public enum CaptureSettingsError: Error, Equatable {
    case invalidTimer
}

@MainActor
@Observable
public final class CaptureSettings {
    private static let timerKey = "getGamen.capture.timerSeconds"
    private static let cursorKey = "getGamen.capture.showsCursor"
    private let defaults: UserDefaults
    public private(set) var snapshot: CaptureSettingsSnapshot

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshot = Self.read(defaults)
    }

    public func setTimerSeconds(_ seconds: Int) throws {
        guard (0...12).contains(seconds) else { throw CaptureSettingsError.invalidTimer }
        defaults.set(seconds, forKey: Self.timerKey)
        snapshot = CaptureSettingsSnapshot(timerSeconds: seconds, showsCursor: snapshot.showsCursor)
    }

    public func setShowsCursor(_ showsCursor: Bool) {
        defaults.set(showsCursor, forKey: Self.cursorKey)
        snapshot = CaptureSettingsSnapshot(timerSeconds: snapshot.timerSeconds, showsCursor: showsCursor)
    }

    /// Reloading defaults never repairs/replaces malformed stored values.
    public func reload() {
        snapshot = Self.read(defaults)
    }

    private static func read(_ defaults: UserDefaults) -> CaptureSettingsSnapshot {
        let timer = timerValue(defaults.object(forKey: timerKey))
        let cursor: Bool
        if let number = defaults.object(forKey: cursorKey) as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            cursor = number.boolValue
        } else {
            cursor = false
        }
        return CaptureSettingsSnapshot(timerSeconds: timer, showsCursor: cursor)
    }

    private static func timerValue(_ object: Any?) -> Int {
        guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let value = number.doubleValue
        guard value.isFinite, (0...12).contains(value), let seconds = Int(exactly: value),
              number.compare(NSNumber(value: seconds)) == .orderedSame else { return 0 }
        return seconds
    }
}
