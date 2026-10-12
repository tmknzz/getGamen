import AppKit
import Carbon
import XCTest
@testable import GetGamen
import GetGamenCore

@MainActor
final class ShortcutSettingsTests: XCTestCase {
    func testGlobalCommandsExcludeScrollCaptureAndKeepOtherCaptureCommands() {
        let commands = ShortcutSettings.globalCommands
        XCTAssertFalse(commands.contains(.captureScroll))
        XCTAssertTrue(commands.contains(.chooser))
        XCTAssertTrue(commands.contains(.captureWindow))
        XCTAssertTrue(commands.contains(.captureRegion))
        XCTAssertTrue(commands.contains(.capturePrevious))
    }

    func testNewCopyShortcutPreservesExistingCustomBindings() throws {
        let suite = "getGamen.shortcut.migration.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = AppCommand.defaultBindings
        old.removeValue(forKey: .copyImage)
        let copyKey = CommandBinding.assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey)))
        old[.toolMask] = copyKey
        defaults.set(try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: old.map { ($0.key.rawValue, $0.value) })), forKey: "getGamen.shortcuts.v1")
        let router = try AppCommandRouting(bindings: AppCommand.defaultBindings, isEnabled: { _ in true }, perform: { _ in })
        let settings = ShortcutSettings(routing: router, defaults: defaults)
        XCTAssertNil(settings.errorMessage)
        XCTAssertEqual(settings.bindings[.toolMask], copyKey)
        XCTAssertEqual(settings.bindings[.copyImage], .unassigned)
        old[.toolMask] = .unassigned
        defaults.set(try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: old.map { ($0.key.rawValue, $0.value) })), forKey: "getGamen.shortcuts.v1")
        let migrated = ShortcutSettings(routing: router, defaults: defaults)
        XCTAssertEqual(migrated.bindings[.copyImage], copyKey)
    }

    func testRecordRebindClearPersistDuplicateRejectionAndNativeTextProtection() throws {
        _ = NSApplication.shared
        let suite = "getGamen.shortcut.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        // Use only local shortcuts in this test so no desktop key ownership changes are needed.
        defer { defaults.removeObject(forKey: "getGamen.shortcuts.v1") }
        var map = AppCommand.defaultBindings
        for command in AppCommand.allCases where command.scope == .globalCapture { map[command] = .unassigned }
        defaults.set(try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })), forKey: "getGamen.shortcuts.v1")
        var actions: [AppCommand] = []
        let routing = try AppCommandRouting(bindings: map, isEnabled: { _ in true }, perform: { actions.append($0) })
        let settings = ShortcutSettings(routing: routing, defaults: defaults)
        settings.install(); defer { try? settings.close(); defaults.removePersistentDomain(forName: suite) }
        let custom = HotKeyShortcut(keyCode: 17, modifiers: UInt32(cmdKey | shiftKey))
        XCTAssertTrue(settings.beginRecording())
        settings.change(.toolMask, to: .assigned(custom))
        XCTAssertNil(settings.errorMessage)
        XCTAssertEqual(routing.bindings[.toolMask], .assigned(custom))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command,.shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "T", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        XCTAssertTrue(routing.performKeyEquivalent(event)); XCTAssertEqual(actions, [.toolMask])
        XCTAssertTrue(settings.beginRecording())
        settings.change(.toolCrop, to: .assigned(custom))
        XCTAssertNotNil(settings.errorMessage)
        XCTAssertEqual(settings.bindings[.toolCrop], .unassigned)
        XCTAssertEqual(settings.bindings[.toolMask], .assigned(custom))
        settings.change(.toolMask, to: .unassigned)
        XCTAssertFalse(routing.performKeyEquivalent(event))
        XCTAssertTrue(settings.beginRecording())
        settings.freeze(); settings.endRecording()
        XCTAssertFalse(settings.beginRecording())
        settings.resume()
        XCTAssertTrue(settings.beginRecording(), "Aborted termination must not leave a stranded recording transaction")
        settings.endRecording()
        XCTAssertEqual(routing.bindings, settings.bindings)
        let reloaded = ShortcutSettings(routing: routing, defaults: defaults)
        XCTAssertEqual(reloaded.bindings[.toolMask], .unassigned)
        let field = NSTextView()
        field.isEditable = true
        field.setMarkedText("かな", selectedRange: NSRange(location: 2,length: 0), replacementRange: NSRange(location: NSNotFound,length: 0))
        XCTAssertTrue(field.hasMarkedText())
        XCTAssertTrue(AppCommandRouting.belongsToNativeTextInput(event, responder: field))
    }
}
