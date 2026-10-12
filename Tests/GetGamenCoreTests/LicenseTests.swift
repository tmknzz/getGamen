import XCTest
@testable import GetGamenCore

private final class StubLicenseAPI: LicenseAPIClient, @unchecked Sendable {
    var activation: LicenseActivationOutcome = .activated(instanceID: "instance")
    var validation: LicenseValidationOutcome = .valid
    var validateCalls = 0
    var deactivation: LicenseDeactivationOutcome = .released
    var deactivateCalls = 0
    func activate(key: String, instanceName: String) async -> LicenseActivationOutcome { activation }
    func validate(key: String, instanceID: String) async -> LicenseValidationOutcome { validateCalls += 1; return validation }
    func deactivate(key: String, instanceID: String) async -> LicenseDeactivationOutcome { deactivateCalls += 1; return deactivation }
}

final class LicenseTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTrialCountsDownAndEndsAfterSevenDays() {
        let record = LicenseRecord(trialStartedAt: start)
        XCTAssertEqual(LicenseManager.computeState(record: record, now: start), .trial(daysRemaining: 7))
        XCTAssertEqual(LicenseManager.computeState(record: record, now: start + 7 * day - 1), .trial(daysRemaining: 1))
        XCTAssertEqual(LicenseManager.computeState(record: record, now: start + 7 * day), .free)
        XCTAssertFalse(LicenseState.free.allowsAutomation)
        XCTAssertTrue(LicenseState.trial(daysRemaining: 1).allowsAutomation)
    }

    func testValidatedKeyIsLicensedWithinOfflineGraceOnly() {
        let activation = LicenseRecord.Activation(key: "k", instanceID: "i")
        let record = LicenseRecord(trialStartedAt: start, activation: activation, lastValidatedAt: start)
        XCTAssertEqual(LicenseManager.computeState(record: record, now: start + 14 * day), .licensed)
        XCTAssertEqual(LicenseManager.computeState(record: record, now: start + 14 * day + 1), .free)
        // A key that failed validation does not fall back to the trial.
        let rejected = LicenseRecord(trialStartedAt: start, activation: activation)
        XCTAssertEqual(LicenseManager.computeState(record: rejected, now: start), .free)
        // A validation time in the future is ignored.
        let tampered = LicenseRecord(trialStartedAt: start, activation: activation, lastValidatedAt: start + day)
        XCTAssertEqual(LicenseManager.computeState(record: tampered, now: start), .free)
    }

    func testResponsesSeparateInvalidFromUnreachable() {
        typealias Client = LemonSqueezyLicenseClient
        func result(_ status: Int?, _ json: String?) -> Client.HTTPResult {
            Client.HTTPResult(statusCode: status, body: json.map { Data($0.utf8) })
        }
        XCTAssertEqual(Client.validationOutcome(from: result(200, #"{"valid":true}"#)), .valid)
        XCTAssertEqual(Client.validationOutcome(from: result(200, #"{"valid":false}"#)), .invalid)
        XCTAssertEqual(Client.validationOutcome(from: result(404, #"{"error":"license_key not found."}"#)), .invalid)
        XCTAssertEqual(Client.validationOutcome(from: result(500, nil)), .unreachable)
        XCTAssertEqual(Client.validationOutcome(from: result(429, nil)), .unreachable)
        XCTAssertEqual(Client.validationOutcome(from: result(nil, nil)), .unreachable)
        // A captive portal's HTML is not an answer from Lemon Squeezy.
        XCTAssertEqual(Client.validationOutcome(from: result(200, "<html>Sign in</html>")), .unreachable)
        XCTAssertEqual(Client.deactivationOutcome(from: result(200, "<html>Sign in</html>")), .unreachable)
        XCTAssertEqual(Client.activationOutcome(from: result(200, #"{"activated":true,"instance":{"id":"abc"}}"#)),
                       .activated(instanceID: "abc"))
        XCTAssertEqual(Client.activationOutcome(from: result(400,
            #"{"activated":false,"error":"This license key has reached the activation limit."}"#)), .activationLimitReached)
        XCTAssertEqual(Client.activationOutcome(from: result(404, #"{"error":"license_key not found."}"#)), .invalidKey)
        XCTAssertEqual(Client.deactivationOutcome(from: result(200, #"{"deactivated":true}"#)), .released)
        XCTAssertEqual(Client.deactivationOutcome(from: result(404, #"{"error":"license_key not found."}"#)), .rejected)
        XCTAssertEqual(Client.deactivationOutcome(from: result(nil, nil)), .unreachable)
        XCTAssertEqual(String(decoding: Client.formBody(["instance_name": "Jo's Mac+Pro & co"]), as: UTF8.self),
                       "instance_name=Jo's%20Mac%2BPro%20%26%20co")
    }

    @MainActor
    func testActivationIsSharedThroughThePrivateFile() async throws {
        let api = StubLicenseAPI()
        var clock = start
        let manager = LicenseManager(directory: directory, api: api, now: { clock })
        XCTAssertEqual(manager.state(), .trial(daysRemaining: 7))
        let permissions = try FileManager.default.attributesOfItem(atPath: manager.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        clock += 8 * day
        XCTAssertEqual(manager.state(), .free)

        let result = await manager.activate(key: "  key  ")
        XCTAssertEqual(result, .success)
        // A second manager reads the same record, as the automation helper does.
        let helper = LicenseManager(directory: directory, api: api, now: { clock })
        let shared = await helper.automationState()
        XCTAssertEqual(shared, .licensed)
        XCTAssertEqual(api.validateCalls, 0)

        // Offline, the key is kept so the activation slot is not left taken.
        api.deactivation = .unreachable
        let offline = await manager.deactivate()
        XCTAssertFalse(offline)
        XCTAssertEqual(helper.state(), .licensed)
        api.deactivation = .released
        let released = await manager.deactivate()
        XCTAssertTrue(released)
        XCTAssertEqual(api.deactivateCalls, 2)
        XCTAssertEqual(helper.state(), .free)
        api.activation = .activationLimitReached
        let limited = await manager.activate(key: "key")
        XCTAssertEqual(limited, .activationLimitReached)
        let empty = await manager.activate(key: " ")
        XCTAssertEqual(empty, .invalidKey)
    }

    @MainActor
    func testRevalidationBacksOffAndChecksOnlineBeforeRefusing() async {
        let api = StubLicenseAPI()
        var clock = start
        let manager = LicenseManager(directory: directory, api: api, now: { clock })
        _ = await manager.activate(key: "key")

        clock += 2 * day
        api.validation = .unreachable
        await manager.revalidate()
        XCTAssertEqual(api.validateCalls, 1)
        XCTAssertEqual(manager.state(), .licensed)
        // Within the retry interval no further check starts.
        let backedOff = await manager.automationState()
        XCTAssertEqual(backedOff, .licensed)
        XCTAssertEqual(api.validateCalls, 1)
        // Back-to-back calls on a stale license start one background check, not one each.
        clock += day
        _ = await manager.automationState()
        _ = await manager.automationState()
        await Task.yield()
        XCTAssertEqual(api.validateCalls, 2)

        clock += 3_600
        api.validation = .invalid
        await manager.revalidate()
        XCTAssertEqual(manager.state(), .free)
        // A lapsed license is checked online before a call is refused.
        clock += 3_600
        api.validation = .valid
        let restored = await manager.automationState()
        XCTAssertEqual(restored, .licensed)
        XCTAssertEqual(api.validateCalls, 4)
    }
}
