import AppKit
import Carbon
import XCTest
@testable import GetGamen
import GetGamenCore

/// Native menu actions and constructed events, plus explicit field-editor predicate fixtures.
/// Foreground keyboard/marked-text/sheet/modal evidence belongs to the separate app-hosted UI suite.
@MainActor
final class AppCommandRoutingTests: XCTestCase {
    func testDefaultsAreCompleteDistinctAndMatchPhysicalContract() throws {
        _ = NSApplication.shared
        let map = AppCommand.defaultBindings
        XCTAssertEqual(Set(map.keys), Set(AppCommand.allCases))
        let captureModifiers = UInt32(controlKey | optionKey | cmdKey)
        let expected: [AppCommand: HotKeyShortcut] = [
            .chooser: chord(49, captureModifiers), .captureWindow: chord(18, captureModifiers),
            .captureRegion: chord(19, captureModifiers), .capturePrevious: chord(20, captureModifiers),
            .captureScroll: chord(21, captureModifiers), .openImages: chord(31),
            .undoEdit: chord(6), .redoEdit: chord(6, UInt32(cmdKey | shiftKey)),
            .copyImage: chord(8), .selectAll: chord(0), .deleteSelection: chord(51, 0),
            .captureCancel: chord(53, 0), .settings: chord(43), .closeWindow: chord(13),
            .quit: chord(12), .hide: chord(4), .minimize: chord(46)
        ]
        for command in AppCommand.allCases {
            XCTAssertEqual(map[command], expected[command].map(CommandBinding.assigned) ?? .unassigned)
            XCTAssertFalse(command.title.isEmpty)
        }
        _ = try AppCommandRouting(bindings: map, isEnabled: { _ in true }, perform: { _ in })
    }

    func testAvailableCommandsExcludeScrollCommandsAndPreserveOrder() {
        let unavailable: Set<AppCommand> = [.captureScroll, .scrollPause, .scrollFinish]
        XCTAssertEqual(AppCommand.available, AppCommand.allCases.filter { !unavailable.contains($0) })
    }

    func testUnavailableScrollPauseBindingDoesNotPerformKeyEquivalent() throws {
        _ = NSApplication.shared
        var actions: [AppCommand] = []
        let routing = try router(perform: { actions.append($0) })
        var map = routing.bindings
        map[.scrollPause] = .assigned(chord(35))
        try routing.replaceBindings(map)
        XCTAssertFalse(routing.performKeyEquivalent(try event(35, characters: "p")))
        XCTAssertTrue(actions.isEmpty)
    }

    func testUnavailableScrollCaptureRegistrationDoesNotPerformButAvailableCommandDoes() throws {
        var actions: [AppCommand] = []
        let routing = try router(perform: { actions.append($0) })
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let scrollShortcut = chord(21, modifiers)
        let regionShortcut = chord(19, modifiers)
        XCTAssertEqual(routing.bindings[.captureScroll], .assigned(scrollShortcut))
        XCTAssertEqual(routing.bindings[.captureRegion], .assigned(regionShortcut))
        routing.performRegistered(.captureScroll, shortcut: scrollShortcut)
        XCTAssertTrue(actions.isEmpty)
        routing.performRegistered(.captureRegion, shortcut: regionShortcut)
        XCTAssertEqual(actions, [.captureRegion])
    }

    func testAvailableCommandCanReuseDefaultScrollCaptureShortcut() {
        var map = AppCommand.defaultBindings
        map[.openImages] = .assigned(chord(21, UInt32(controlKey | optionKey | cmdKey)))
        XCTAssertNoThrow(try AppCommandRouting.validate(map))
    }

    func testRejectedMapReplacementPreservesWholePriorMap() throws {
        let routing = try router()
        let original = routing.bindings
        var missing = original
        missing.removeValue(forKey: .quit)
        assertReplacement(routing, missing, error: .incompleteBindings)
        var duplicate = original
        duplicate[.quit] = original[.hide]
        assertReplacement(routing, duplicate, error: .duplicateShortcut)
        for invalid in [chord(UInt32(UInt16.max) + 1), chord(12, UInt32(cmdKey) | (1 << 31))] {
            var map = original
            map[.quit] = .assigned(invalid)
            assertReplacement(routing, map, error: .invalidShortcut)
        }
        XCTAssertEqual(routing.bindings, original)
        XCTAssertThrowsError(try AppCommandRouting(bindings: missing, isEnabled: { _ in true }, perform: { _ in })) {
            XCTAssertEqual($0 as? AppCommandRoutingError, .incompleteBindings)
        }
    }

    func testPhysicalIdentityModifiersAndNonKeyOrRepeatEvents() throws {
        _ = NSApplication.shared
        var actions: [AppCommand] = []
        let routing = try router(perform: { actions.append($0) })
        let menu = AppCommandMenu(title: "Test", routing: routing)
        menu.addItem(AppCommandMenuItem(command: .quit, routing: routing))
        XCTAssertTrue(menu.performKeyEquivalent(with: try event(12, characters: "å")))
        XCTAssertTrue(menu.performKeyEquivalent(with: try event(12, modifiers: [.command, .capsLock, .function, .numericPad], characters: "Q")))
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(13, modifiers: [.command, .option], characters: "q")))
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(12, modifiers: [.command, .shift])))
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(12, modifiers: [])))
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(12, repeatEvent: true)))
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(12, type: .keyUp)))
        XCTAssertEqual(actions, [.quit, .quit])
    }

    func testRebindingClearingAndAttemptedStaleCharacterEquivalentHaveNoSecondRoute() throws {
        _ = NSApplication.shared
        var actions: [AppCommand] = []
        let routing = try router(perform: { actions.append($0) })
        let menu = AppCommandMenu(title: "Test", routing: routing)
        let item = AppCommandMenuItem(command: .quit, routing: routing)
        menu.addItem(item)
        item.keyEquivalent = "q"
        item.keyEquivalentModifierMask = [.command]
        XCTAssertEqual(item.keyEquivalent, "")
        var map = routing.bindings
        map[.selectAll] = .unassigned
        map[.quit] = .assigned(chord(0))
        try routing.replaceBindings(map)
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(12)))
        XCTAssertTrue(menu.performKeyEquivalent(with: try event(0)))
        map[.quit] = .unassigned
        try routing.replaceBindings(map)
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(0)))
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(12)))
        menu.performActionForItem(at: 0)
        XCTAssertEqual(actions, [.quit, .quit], "An unassigned command still works by actual menu action")
        XCTAssertEqual(item.command, .quit)
    }

    func testNativeItemFallbackAndOwnedItemValidation() throws {
        _ = NSApplication.shared
        var enabled = true
        var actions: [AppCommand] = []
        let routing = try AppCommandRouting(bindings: AppCommand.defaultBindings,
                                           isEnabled: { _ in enabled }, perform: { actions.append($0) })
        let menu = AppCommandMenu(title: "Test", routing: routing)
        let owned = AppCommandMenuItem(command: .quit, routing: routing)
        let receiver = NativeMenuReceiver()
        let native = NSMenuItem(title: "Native fallback", action: #selector(NativeMenuReceiver.receive(_:)), keyEquivalent: "b")
        native.target = receiver
        native.keyEquivalentModifierMask = [.command]
        menu.addItem(owned)
        menu.addItem(native)
        XCTAssertTrue(menu.performKeyEquivalent(with: try event(11, characters: "b")))
        XCTAssertEqual(receiver.calls, 1)
        XCTAssertTrue(actions.isEmpty)
        menu.update()
        XCTAssertTrue(owned.isEnabled)
        enabled = false
        menu.update()
        XCTAssertFalse(owned.isEnabled)
        XCTAssertFalse(routing.isEnabled(.quit))
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(12)))
        menu.performActionForItem(at: 0)
        XCTAssertTrue(actions.isEmpty)
    }

    func testGlobalCommandsNeverUseLocalDispatchAndStaleRegistrationCallbackIsRejected() throws {
        _ = NSApplication.shared
        var actions: [AppCommand] = []
        let routing = try router(perform: { actions.append($0) })
        let menu = AppCommandMenu(title: "Test", routing: routing)
        let old = chord(18, UInt32(cmdKey | controlKey | optionKey))
        XCTAssertFalse(menu.performKeyEquivalent(with: try event(18, modifiers: [.command, .control, .option], characters: "1")))
        routing.performRegistered(.captureWindow, shortcut: old)
        routing.performRegistered(.quit, shortcut: chord(12))
        var map = routing.bindings
        let replacement = chord(23, old.modifiers)
        map[.captureWindow] = .assigned(replacement)
        try routing.replaceBindings(map)
        routing.performRegistered(.captureWindow, shortcut: old)
        routing.performRegistered(.captureWindow, shortcut: replacement)
        map[.captureWindow] = .unassigned
        try routing.replaceBindings(map)
        routing.performRegistered(.captureWindow, shortcut: replacement)
        XCTAssertEqual(actions, [.captureWindow, .captureWindow])
    }

    func testUnmarkedNativeFieldEditorOwnsEveryNonCommandChord() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 220, height: 30))
        window.contentView?.addSubview(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertFalse(editor.hasMarkedText())

        let nativeChords: [(UInt16, NSEvent.ModifierFlags, String)] = [
            (UInt16(kVK_ANSI_A), [], "a"),
            (UInt16(kVK_Return), [], "\r"),
            (UInt16(kVK_Delete), [], "\u{7f}"),
            (UInt16(kVK_LeftArrow), [], "\u{f702}"),
            (UInt16(kVK_ANSI_A), [.control], "\u{1}"),
            (UInt16(kVK_ANSI_A), [.option], "å")
        ]
        for (key, modifiers, characters) in nativeChords {
            XCTAssertTrue(AppCommandRouting.belongsToNativeTextInput(
                try event(key, modifiers: modifiers, characters: characters), responder: editor
            ))
        }
        XCTAssertTrue(AppCommandRouting.belongsToNativeTextInput(
            try event(UInt16(kVK_ANSI_C), characters: "c"), responder: editor
        ))
        XCTAssertFalse(AppCommandRouting.belongsToNativeTextInput(
            try event(UInt16(kVK_ANSI_Q), characters: "q"), responder: editor
        ))
    }

    private func chord(_ key: UInt32, _ modifiers: UInt32 = UInt32(cmdKey)) -> HotKeyShortcut {
        HotKeyShortcut(keyCode: key, modifiers: modifiers)
    }

    private func router(perform: @escaping @MainActor (AppCommand) -> Void = { _ in }) throws -> AppCommandRouting {
        try AppCommandRouting(bindings: AppCommand.defaultBindings, isEnabled: { _ in true }, perform: perform)
    }

    private func assertReplacement(_ routing: AppCommandRouting, _ bindings: [AppCommand: CommandBinding],
                                   error: AppCommandRoutingError, file: StaticString = #filePath, line: UInt = #line) {
        let original = routing.bindings
        XCTAssertThrowsError(try routing.replaceBindings(bindings), file: file, line: line) {
            XCTAssertEqual($0 as? AppCommandRoutingError, error, file: file, line: line)
        }
        XCTAssertEqual(routing.bindings, original, file: file, line: line)
    }

    private func event(_ key: UInt16, modifiers: NSEvent.ModifierFlags = [.command], characters: String = "q",
                       repeatEvent: Bool = false, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                       timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: repeatEvent, keyCode: key))
    }

}

@MainActor
private final class NativeMenuReceiver: NSObject {
    var calls = 0
    @objc func receive(_ sender: Any?) { calls += 1 }
}
