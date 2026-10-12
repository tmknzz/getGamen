import Foundation
import CoreFoundation
import Observation
import XCTest
import GetGamenCore

final class CaptureSettingsTests: XCTestCase {
    private let timerKey = "getGamen.capture.timerSeconds"
    private let cursorKey = "getGamen.capture.showsCursor"

    @MainActor
    func testMissingFieldsUseDefaultsWithoutWritingThem() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureSettings(defaults: defaults)
        XCTAssertEqual(settings.snapshot, CaptureSettingsSnapshot(timerSeconds: 0, showsCursor: false))
        settings.reload()
        XCTAssertNil(defaults.object(forKey: timerKey))
        XCTAssertNil(defaults.object(forKey: cursorKey))
    }

    @MainActor
    func testSettersPersistActualTypesAndReopenAtAllBoundaryValues() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureSettings(defaults: defaults)
        for seconds in [0, 1, 3, 5, 10, 12] {
            for cursor in [false, true] {
                try settings.setTimerSeconds(seconds)
                settings.setShowsCursor(cursor)
                let reopened = CaptureSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
                XCTAssertEqual(reopened.snapshot, CaptureSettingsSnapshot(timerSeconds: seconds, showsCursor: cursor))
                let storedTimer = try XCTUnwrap(defaults.object(forKey: timerKey) as? NSNumber)
                let storedCursor = try XCTUnwrap(defaults.object(forKey: cursorKey) as? NSNumber)
                XCTAssertNotEqual(CFGetTypeID(storedTimer), CFBooleanGetTypeID())
                XCTAssertEqual(storedTimer.intValue, seconds)
                XCTAssertEqual(CFGetTypeID(storedCursor), CFBooleanGetTypeID())
                XCTAssertEqual(storedCursor.boolValue, cursor)
            }
        }
    }

    @MainActor
    func testInvalidSetterLeavesSnapshotAndBothStoredFieldsUnchanged() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureSettings(defaults: defaults)
        try settings.setTimerSeconds(4)
        settings.setShowsCursor(true)
        let snapshot = settings.snapshot
        let before = try XCTUnwrap(defaults.persistentDomain(forName: name)) as NSDictionary
        for invalid in [-1, 13, Int.min, Int.max] {
            XCTAssertThrowsError(try settings.setTimerSeconds(invalid)) {
                XCTAssertEqual($0 as? CaptureSettingsError, .invalidTimer)
            }
            XCTAssertEqual(settings.snapshot, snapshot)
            XCTAssertEqual(try XCTUnwrap(defaults.persistentDomain(forName: name)) as NSDictionary, before)
        }
    }

    @MainActor
    func testMalformedTimerDefaultsIndependentlyWithoutRewritingStorage() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: cursorKey)
        let malformed: [Any] = ["5", NSNumber(value: true), NSNumber(value: false),
                                NSNumber(value: 2.5), NSNumber(value: -1), NSNumber(value: 13),
                                [1, 2], ["seconds": 2], Data([1, 2, 3])]
        for value in malformed {
            defaults.set(value, forKey: timerKey)
            let before = try XCTUnwrap(defaults.persistentDomain(forName: name)) as NSDictionary
            let settings = CaptureSettings(defaults: defaults)
            XCTAssertEqual(settings.snapshot, CaptureSettingsSnapshot(timerSeconds: 0, showsCursor: true))
            settings.reload()
            XCTAssertEqual(settings.snapshot, CaptureSettingsSnapshot(timerSeconds: 0, showsCursor: true))
            XCTAssertEqual(try XCTUnwrap(defaults.persistentDomain(forName: name)) as NSDictionary, before)
        }
    }

    @MainActor
    func testNonfiniteStoredNumbersDefaultWithoutReplacingTheirValues() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: cursorKey)
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            defaults.set(NSNumber(value: value), forKey: timerKey)
            let before = try XCTUnwrap(defaults.object(forKey: timerKey) as? NSNumber)
            XCTAssertFalse(before.doubleValue.isFinite)
            let settings = CaptureSettings(defaults: defaults)
            settings.reload()
            XCTAssertEqual(settings.snapshot, CaptureSettingsSnapshot(timerSeconds: 0, showsCursor: true))
            let after = try XCTUnwrap(defaults.object(forKey: timerKey) as? NSNumber)
            // NaN is not reflexively equal; compare its classification instead of dictionary equality.
            if value.isNaN { XCTAssertTrue(after.doubleValue.isNaN) }
            else { XCTAssertEqual(after.doubleValue, value) }
            XCTAssertNotEqual(CFGetTypeID(after), CFBooleanGetTypeID())
            XCTAssertEqual(defaults.object(forKey: cursorKey) as? NSNumber, NSNumber(value: true))
        }
    }

    @MainActor
    func testCursorRequiresBooleanRatherThanNumericOrStringCoercion() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(7, forKey: timerKey)
        for value: Any in [NSNumber(value: 1), NSNumber(value: 0), "true", "false", [true], Data([1])] {
            defaults.set(value, forKey: cursorKey)
            let before = try XCTUnwrap(defaults.persistentDomain(forName: name)) as NSDictionary
            let settings = CaptureSettings(defaults: defaults)
            XCTAssertEqual(settings.snapshot, CaptureSettingsSnapshot(timerSeconds: 7, showsCursor: false))
            settings.reload()
            XCTAssertEqual(try XCTUnwrap(defaults.persistentDomain(forName: name)) as NSDictionary, before)
        }
    }

    @MainActor
    func testIntegralFloatingNumbersAreAcceptedButStoredPrecisionIsNotRoundedAway() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        for value in [NSNumber(value: 1.0), NSNumber(value: 10.0)] {
            defaults.set(value, forKey: timerKey)
            XCTAssertEqual(CaptureSettings(defaults: defaults).snapshot.timerSeconds, value.intValue)
        }
        defaults.set(NSDecimalNumber(string: "1.0000000000000000001"), forKey: timerKey)
        let actual = try XCTUnwrap(defaults.object(forKey: timerKey) as? NSNumber)
        // Judge the actual stored object. UserDefaults may already have lost the source precision.
        let retainsFraction = actual.decimalValue != Decimal(1)
        XCTAssertEqual(CaptureSettings(defaults: defaults).snapshot.timerSeconds, retainsFraction ? 0 : 1)
    }

    @MainActor
    func testReloadReadsExternalChangesAndOldSnapshotRemainsAnImmutableValue() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureSettings(defaults: defaults)
        try settings.setTimerSeconds(3)
        settings.setShowsCursor(true)
        let captured = settings.snapshot
        let other = try XCTUnwrap(UserDefaults(suiteName: name))
        other.set(9, forKey: timerKey)
        other.set(false, forKey: cursorKey)
        XCTAssertEqual(settings.snapshot, captured, "Reload is explicit; no independent live AppStorage state")
        settings.reload()
        XCTAssertEqual(settings.snapshot, CaptureSettingsSnapshot(timerSeconds: 9, showsCursor: false))
        XCTAssertEqual(captured, CaptureSettingsSnapshot(timerSeconds: 3, showsCursor: true))
        other.removeObject(forKey: timerKey)
        settings.reload()
        XCTAssertEqual(settings.snapshot, CaptureSettingsSnapshot(timerSeconds: 0, showsCursor: false))
        XCTAssertNil(other.object(forKey: timerKey))
    }

    @MainActor
    func testSnapshotIsObservableForSettingsUI() throws {
        let (name, defaults) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureSettings(defaults: defaults)
        let changed = XCTestExpectation(description: "Snapshot Observation change")
        withObservationTracking {
            _ = settings.snapshot
        } onChange: {
            changed.fulfill()
        }
        try settings.setTimerSeconds(2)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1), .completed)
    }

    private func suite() throws -> (String, UserDefaults) {
        let name = "getGamen.CaptureSettingsTests.\(UUID().uuidString)"
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }
}
