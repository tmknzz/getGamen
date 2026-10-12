import AppKit
import Carbon
import XCTest
@testable import GetGamenCore

final class GlobalHotKeyRegistryTests: XCTestCase {
    func testModifierConversionUsesCarbonBits() {
        let flags: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .capsLock]
        XCTAssertEqual(HotKeyShortcut.carbonModifiers(from: flags),
                       UInt32(cmdKey | controlKey | optionKey | shiftKey))
        XCTAssertEqual(HotKeyShortcut.carbonModifiers(from: []), 0)
    }

    func testNativeRegistrationConflictReleaseAndReregistration() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let first = try GlobalHotKeyRegistry()
            let second = try GlobalHotKeyRegistry()
            defer { close(first); close(second) }
            let key = try registerAvailable(first, id: 1)
            XCTAssertEqual(first.shortcuts[1], key)
            XCTAssertThrowsError(try second.register(id: 1, shortcut: key, action: {}))
            XCTAssertTrue(second.shortcuts.isEmpty)
            XCTAssertEqual(first.shortcuts[1], key)
            try first.unregister(id: 1)
            XCTAssertTrue(first.shortcuts.isEmpty)
            try second.register(id: 1, shortcut: key, action: {})
            XCTAssertEqual(second.shortcuts[1], key)
            try second.close()
            XCTAssertTrue(second.shortcuts.isEmpty)
            XCTAssertThrowsError(try second.register(id: 2, shortcut: key, action: {})) {
                XCTAssertEqual($0 as? HotKeyRegistryError, .closed)
            }
        }
    }

    func testFailedReplacementPreservesOldRegistrationAndSameAppDuplicatesReject() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let first = try GlobalHotKeyRegistry()
            let blocker = try GlobalHotKeyRegistry()
            defer { close(first); close(blocker) }
            let old = try registerAvailable(first, id: 41)
            var delivered = 0
            try first.register(id: 41, shortcut: old) { delivered += 1 }
            let oldID = try XCTUnwrap(first.eventIdentifier(for: 41))
            let occupied = try registerAvailable(blocker, id: 41, excluding: [old])
            XCTAssertThrowsError(try first.register(id: 41, shortcut: occupied, action: {}))
            XCTAssertEqual(first.shortcuts[41], old)
            XCTAssertEqual(first.eventIdentifier(for: 41)?.id, oldID.id)
            try deliver(oldID)
            XCTAssertEqual(delivered, 1)
            XCTAssertThrowsError(try blocker.register(id: 99, shortcut: old, action: {}))
            XCTAssertThrowsError(try first.register(id: 42, shortcut: old, action: {})) {
                XCTAssertEqual($0 as? HotKeyRegistryError, .duplicateShortcut)
            }
            XCTAssertEqual(first.shortcuts.count, 1)
            try blocker.unregister(id: 41)
            try first.register(id: 41, shortcut: occupied, action: {})
            XCTAssertEqual(first.shortcuts[41], occupied)
            // A successful replacement must release the old OS registration.
            try blocker.register(id: 41, shortcut: old, action: {})
        }
    }

    func testNativeEventRoutingSeparatesEqualPublicIDsAndUpdatesActions() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let first = try GlobalHotKeyRegistry()
            let second = try GlobalHotKeyRegistry()
            defer { close(first); close(second) }
            var firstCount = 0
            var secondCount = 0
            let key = try registerAvailable(first, id: 7)
            let other = try registerAvailable(second, id: 7, excluding: [key])
            try first.register(id: 7, shortcut: key) { firstCount += 1 }
            try second.register(id: 7, shortcut: other) { secondCount += 1 }
            let firstID = try XCTUnwrap(first.eventIdentifier(for: 7))
            let secondID = try XCTUnwrap(second.eventIdentifier(for: 7))
            XCTAssertNotEqual(firstID.id, secondID.id)
            try deliver(firstID)
            XCTAssertEqual(firstCount, 1)
            XCTAssertEqual(secondCount, 0)
            try deliver(secondID)
            XCTAssertEqual(firstCount, 1)
            XCTAssertEqual(secondCount, 1)
            try first.register(id: 7, shortcut: key) { firstCount += 10 }
            try deliver(try XCTUnwrap(first.eventIdentifier(for: 7)))
            XCTAssertEqual(firstCount, 11)
            XCTAssertEqual(secondCount, 1)
        }
    }

    func testEnabledOSSymbolicShortcutIsRejected() async throws {
        try await MainActor.run {
            var unmanaged: Unmanaged<CFArray>?
            let status = CopySymbolicHotKeys(&unmanaged)
            XCTAssertEqual(status, noErr)
            let native: CFArray = try XCTUnwrap(unmanaged?.takeRetainedValue())
            let array = native as NSArray
            let shortcuts = array.compactMap { item -> HotKeyShortcut? in
                guard let item = item as? NSDictionary,
                      (item[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
                      let code = item[kHISymbolicHotKeyCode] as? NSNumber,
                      let modifiers = item[kHISymbolicHotKeyModifiers] as? NSNumber else { return nil }
                return HotKeyShortcut(keyCode: code.uint32Value, modifiers: modifiers.uint32Value)
            }
            guard let shortcut = shortcuts.first else { throw XCTSkip("No enabled OS symbolic key on this host") }
            let registry = try GlobalHotKeyRegistry(); defer { close(registry) }
            XCTAssertThrowsError(try registry.register(id: 1, shortcut: shortcut, action: {})) {
                XCTAssertEqual($0 as? HotKeyRegistryError, .reservedSystemShortcut)
            }
            XCTAssertTrue(registry.shortcuts.isEmpty)
        }
    }

    func testInvalidValuesNeverPublishRegistration() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let registry = try GlobalHotKeyRegistry()
            defer { close(registry) }
            let invalid = [HotKeyShortcut(keyCode: UInt32.max, modifiers: 0),
                           HotKeyShortcut(keyCode: 0, modifiers: 1 << 31)]
            for key in invalid {
                XCTAssertThrowsError(try registry.register(id: 1, shortcut: key, action: {})) {
                    XCTAssertEqual($0 as? HotKeyRegistryError, .invalidShortcut)
                }
                XCTAssertTrue(registry.shortcuts.isEmpty)
            }
        }
    }

    func testOffMainDeinitReleasesNativeRegistration() async throws {
        let (box, key) = try await MainActor.run {
            _ = NSApplication.shared
            let registry = try GlobalHotKeyRegistry()
            let key = try registerAvailable(registry, id: 81)
            return (ReleaseBox(registry), key)
        }
        await Task.detached { box.value = nil }.value
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        try await MainActor.run {
            let replacement = try GlobalHotKeyRegistry()
            defer { close(replacement) }
            try replacement.register(id: 81, shortcut: key, action: {})
            XCTAssertEqual(replacement.shortcuts[81], key)
        }
    }

    // A single owner is transferred to a detached task, then never accessed again.
    private final class ReleaseBox: @unchecked Sendable {
        var value: GlobalHotKeyRegistry?
        init(_ value: GlobalHotKeyRegistry) { self.value = value }
    }

    @MainActor
    private func registerAvailable(_ registry: GlobalHotKeyRegistry, id: UInt32,
                                   excluding: Set<HotKeyShortcut> = []) throws -> HotKeyShortcut {
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let codes = [kVK_F18, kVK_F19, kVK_F20, kVK_F17, kVK_F16, kVK_F15]
        var errors: [String] = []
        for code in codes {
            let key = HotKeyShortcut(keyCode: UInt32(code), modifiers: modifiers)
            if excluding.contains(key) { continue }
            do {
                try registry.register(id: id, shortcut: key, action: {})
                print("Native hotkey registered keyCode=\(code), modifiers=\(modifiers)")
                return key
            } catch {
                errors.append("\(code): \(error)")
            }
        }
        XCTFail("No native hotkey candidate could register: \(errors)")
        throw TestFailure.noAvailableKey
    }

    @MainActor
    private func close(_ registry: GlobalHotKeyRegistry,
                       file: StaticString = #filePath, line: UInt = #line) {
        do { try registry.close() }
        catch { XCTFail("Native hotkey cleanup failed: \(error)", file: file, line: line) }
    }

    @MainActor
    private func deliver(_ identifier: EventHotKeyID) throws {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   GetCurrentEventTime(), 0, &event), noErr)
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        var identifier = identifier
        XCTAssertEqual(SetEventParameter(created, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        XCTAssertEqual(SendEventToEventTarget(created, GetApplicationEventTarget()), noErr)
    }

    private enum TestFailure: Error { case noAvailableKey }
}
