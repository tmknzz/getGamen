import Foundation
import SystemConfiguration

/// The CLI and MCP server need a license; manual GUI use stays free.
public enum LicenseConfig {
    public static let purchaseURL = URL(string: "https://tmknzz.lemonsqueezy.com/checkout/buy/2af738c0-6a22-457e-a868-06df153c2d27")!
    public static let trialDays = 7
    /// A license stays valid this long after the last successful online check.
    public static let offlineGraceDays = 14
    public static let revalidateAfterHours = 24
    /// After an online check starts, wait this long before starting another.
    static let retryAfterMinutes = 15
}

public enum LicenseState: Equatable, Sendable {
    case trial(daysRemaining: Int)
    case licensed
    case free

    public var allowsAutomation: Bool { self != .free }
}

public enum LicenseActivationResult: Equatable, Sendable {
    case success
    case invalidKey
    case activationLimitReached
    case offline
    case storageFailed
}

struct LicenseRecord: Codable, Equatable {
    struct Activation: Codable, Equatable {
        var key: String
        var instanceID: String
    }
    var trialStartedAt: Date?
    var activation: Activation?
    var lastValidatedAt: Date?
    var lastAttemptAt: Date?
}

/// License state shared by the GUI and the automation helper. They have different bundle IDs,
/// so the record is a file both can read rather than per-app defaults or a keychain item
/// (a keychain item created by one app prompts when the other reads it).
@MainActor
public final class LicenseManager {
    nonisolated public static var defaultDirectory: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["GETGAMEN_LICENSE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("getGamen/License", isDirectory: true)
    }

    let fileURL: URL
    private let api: any LicenseAPIClient
    private let now: () -> Date

    public convenience init(directory: URL = LicenseManager.defaultDirectory) {
        self.init(directory: directory, api: LemonSqueezyLicenseClient(), now: Date.init)
    }

    init(directory: URL, api: any LicenseAPIClient, now: @escaping () -> Date) {
        fileURL = directory.appendingPathComponent("license.json")
        self.api = api
        self.now = now
    }

    /// Current state from the local record. Starts the trial on first use.
    public func state() -> LicenseState {
        Self.computeState(record: loadStartingTrial(), now: now())
    }

    /// State for an automation call. Within the offline grace a stale license is rechecked in
    /// the background, so calls never wait on the network; once the license has lapsed it is
    /// checked online before the call is refused. A one-shot CLI process may exit before the
    /// background check finishes; it then checks online once the grace runs out.
    public func automationState() async -> LicenseState {
        let record = loadStartingTrial()
        let current = Self.computeState(record: record, now: now())
        guard let activation = beginRevalidation(record) else { return current }
        guard current == .free else {
            Task { await finishRevalidation(activation) }
            return current
        }
        await finishRevalidation(activation)
        return state()
    }

    func revalidate() async {
        if let activation = beginRevalidation(load()) { await finishRevalidation(activation) }
    }

    /// Records the attempt before any await, so concurrent callers back off instead of checking again.
    private func beginRevalidation(_ record: LicenseRecord) -> LicenseRecord.Activation? {
        var record = record
        guard let activation = record.activation, Self.needsRevalidation(record: record, now: now()) else { return nil }
        record.lastAttemptAt = now()
        try? save(record)
        return activation
    }

    private func finishRevalidation(_ activation: LicenseRecord.Activation) async {
        let outcome = await api.validate(key: activation.key, instanceID: activation.instanceID)
        // The other app, or another call, may have changed the activation while this waited.
        var latest = load()
        guard latest.activation == activation else { return }
        switch outcome {
        case .valid: latest.lastValidatedAt = now()
        // Keep the key so a license re-enabled in the dashboard recovers without a new activation.
        case .invalid: latest.lastValidatedAt = nil
        case .unreachable: return
        }
        try? save(latest)
    }

    public func activate(key: String) async -> LicenseActivationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidKey }
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        switch await api.activate(key: trimmed, instanceName: name) {
        case .activated(let instanceID):
            var record = load()
            record.activation = .init(key: trimmed, instanceID: instanceID)
            record.lastValidatedAt = now()
            do { try save(record) } catch {
                // Give the activation slot back rather than leaking it.
                _ = await api.deactivate(key: trimmed, instanceID: instanceID)
                return .storageFailed
            }
            return .success
        case .invalidKey: return .invalidKey
        case .activationLimitReached: return .activationLimitReached
        case .unreachable: return .offline
        }
    }

    /// Releases the activation slot, then forgets the key. When Lemon Squeezy cannot be reached the
    /// key is kept and this returns false, so the slot is not left taken by a Mac that forgot its key.
    public func deactivate() async -> Bool {
        guard let activation = load().activation else { return true }
        guard await api.deactivate(key: activation.key, instanceID: activation.instanceID) != .unreachable else { return false }
        // Leave an activation the other app made while this waited.
        let latest = load()
        if latest.activation == activation {
            try? save(LicenseRecord(trialStartedAt: latest.trialStartedAt))
        }
        return true
    }

    nonisolated static func computeState(record: LicenseRecord, now: Date) -> LicenseState {
        // A key that failed or never passed validation does not fall back to the trial,
        // and a validation time in the future is treated as tampering, not as "checked now".
        if record.activation != nil {
            guard let validated = record.lastValidatedAt, validated <= now else { return .free }
            let graceEnd = validated.addingTimeInterval(Double(LicenseConfig.offlineGraceDays) * 86_400)
            return now <= graceEnd ? .licensed : .free
        }
        let start = min(record.trialStartedAt ?? now, now)
        let trialEnd = start.addingTimeInterval(Double(LicenseConfig.trialDays) * 86_400)
        guard now < trialEnd else { return .free }
        return .trial(daysRemaining: Int((trialEnd.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    nonisolated static func needsRevalidation(record: LicenseRecord, now: Date) -> Bool {
        if let attempt = record.lastAttemptAt, attempt <= now,
           now.timeIntervalSince(attempt) < Double(LicenseConfig.retryAfterMinutes) * 60 { return false }
        guard let validated = record.lastValidatedAt, validated <= now else { return true }
        return now.timeIntervalSince(validated) > Double(LicenseConfig.revalidateAfterHours) * 3_600
    }

    private func loadStartingTrial() -> LicenseRecord {
        var record = load()
        if record.trialStartedAt == nil {
            record.trialStartedAt = now()
            try? save(record)
        }
        return record
    }

    private func load() -> LicenseRecord {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(LicenseRecord.self, from: data) else { return LicenseRecord() }
        return record
    }

    private func save(_ record: LicenseRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Also tighten a directory that already existed, since the atomic write briefly creates a 0644 file.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
