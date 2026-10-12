import AppKit
import Carbon
import GetGamenCore

enum AppCommandRoutingError: Error, Equatable {
    case incompleteBindings, invalidShortcut, duplicateShortcut
}

/// One physical-key authority for app commands. Global registration is owned separately.
@MainActor
final class AppCommandRouting {
    private(set) var bindings: [AppCommand: CommandBinding]
    private let enabled: @MainActor (AppCommand) -> Bool
    private let action: @MainActor (AppCommand) -> Void

    init(bindings: [AppCommand: CommandBinding],
         isEnabled: @escaping @MainActor (AppCommand) -> Bool,
         perform: @escaping @MainActor (AppCommand) -> Void) throws {
        try Self.validate(bindings)
        self.bindings = bindings
        enabled = isEnabled
        action = perform
    }

    /// Registration/persistence owners call this only after their own transaction succeeds.
    func replaceBindings(_ bindings: [AppCommand: CommandBinding]) throws {
        try Self.validate(bindings)
        self.bindings = bindings
    }

    func isEnabled(_ command: AppCommand) -> Bool { enabled(command) }

    func perform(_ command: AppCommand) {
        guard enabled(command) else { return }
        action(command)
    }

    func performRegistered(_ command: AppCommand, shortcut: HotKeyShortcut) {
        guard command.isAvailable, command.scope == .globalCapture,
              bindings[command] == .assigned(shortcut) else { return }
        perform(command)
    }

    func performKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat, !belongsToNativeInput(event) else { return false }
        let shortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode),
                                      modifiers: HotKeyShortcut.carbonModifiers(from: event.modifierFlags))
        guard let command = AppCommand.allCases.first(where: {
            $0.isAvailable && $0.scope == .localApplication && bindings[$0] == .assigned(shortcut)
        }), enabled(command) else { return false }
        action(command)
        return true
    }

    private func belongsToNativeInput(_ event: NSEvent) -> Bool {
        let window = NSApplication.shared.keyWindow
        if let recorder = window?.firstResponder as? ShortcutRecorderView, recorder.isRecording { return true }
        if NSApplication.shared.modalWindow != nil || window?.sheetParent != nil || window?.attachedSheet != nil {
            return true
        }
        return Self.belongsToNativeTextInput(event, responder: window?.firstResponder)
    }

    static func belongsToNativeTextInput(_ event: NSEvent, responder: NSResponder?) -> Bool {
        guard let text = responder as? NSTextView, text.isEditable || text.isSelectable else { return false }
        if text.hasMarkedText() { return true }
        let command = event.modifierFlags.contains(.command)
        if !command { return true }
        if command, let characters = event.charactersIgnoringModifiers?.lowercased(),
           ["c", "v", "x", "a", "z"].contains(characters) { return true }
        return false
    }

    static func validate(_ bindings: [AppCommand: CommandBinding]) throws {
        guard Set(bindings.keys) == Set(AppCommand.allCases) else {
            throw AppCommandRoutingError.incompleteBindings
        }
        let allowed = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        var seen = Set<HotKeyShortcut>()
        for (command, binding) in bindings {
            guard case .assigned(let shortcut) = binding else { continue }
            guard shortcut.keyCode <= 127, shortcut.modifiers & ~allowed == 0 else {
                throw AppCommandRoutingError.invalidShortcut
            }
            guard command.isAvailable else { continue }
            guard seen.insert(shortcut).inserted else { throw AppCommandRoutingError.duplicateShortcut }
        }
    }
}

@MainActor
final class AppCommandMenu: NSMenu {
    private let routing: AppCommandRouting

    init(title: String, routing: AppCommandRouting) {
        self.routing = routing
        super.init(title: title)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init(title:routing:)") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        routing.performKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }
}

/// Native character equivalents must never become a second route for an owned command.
@MainActor
final class AppCommandMenuItem: NSMenuItem, NSMenuItemValidation {
    let command: AppCommand
    private let routing: AppCommandRouting

    init(command: AppCommand, routing: AppCommandRouting) {
        self.command = command
        self.routing = routing
        super.init(title: command.title, action: nil, keyEquivalent: "")
        keyEquivalentModifierMask = []
        target = self
        action = #selector(invokeCommand(_:))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init(command:routing:)") }

    override var keyEquivalent: String {
        get { "" }
        set { super.keyEquivalent = "" }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { routing.isEnabled(command) }

    @objc private func invokeCommand(_ sender: Any?) { routing.perform(command) }
}
