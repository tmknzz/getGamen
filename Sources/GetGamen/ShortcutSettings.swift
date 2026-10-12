import AppKit
import Carbon
import Observation
import SwiftUI
import GetGamenCore

@MainActor
@Observable
final class ShortcutSettings {
    static var globalCommands: [AppCommand] { AppCommand.available.filter { $0.scope == .globalCapture } }
    private(set) var bindings: [AppCommand: CommandBinding]
    private(set) var errorMessage: String?
    private(set) var frozen = false
    private let defaults: UserDefaults
    private let routing: AppCommandRouting
    private var registry: GlobalHotKeyRegistry?
    private var recording = false
    private var recordingOriginal: [UInt32: HotKeyShortcut]?
    private let key = "getGamen.shortcuts.v1"
    var didChange: (() -> Void)?

    init(routing: AppCommandRouting, defaults: UserDefaults) {
        self.routing = routing; self.defaults = defaults
        var initial = AppCommand.defaultBindings
        if let data = defaults.data(forKey: key) {
            do {
                let saved = try JSONDecoder().decode([String: CommandBinding].self, from: data)
                for (name, binding) in saved { if let command = AppCommand(rawValue: name) { initial[command] = binding } }
                // A newly added default must not override an existing custom key.
                for command in AppCommand.allCases where saved[command.rawValue] == nil {
                    if case .assigned(let shortcut) = initial[command], saved.values.contains(.assigned(shortcut)) {
                        initial[command] = .unassigned
                    }
                }
                try AppCommandRouting.validate(initial)
            } catch {
                errorMessage = "保存されたショートカットが無効です。既定値を使用します。\(error.localizedDescription)"
                initial = AppCommand.defaultBindings
            }
        }
        bindings = initial
    }

    func install() {
        do {
            registry = try GlobalHotKeyRegistry()
            var actual = bindings
            var failures: [String] = []
            for command in Self.globalCommands {
                if case .assigned(let key) = bindings[command] {
                    do { try register(command, key) }
                    catch { actual[command] = .unassigned; failures.append("\(command.title): \(error)") }
                }
            }
            try routing.replaceBindings(actual); bindings = actual; didChange?()
            if !failures.isEmpty { errorMessage = "登録できなかったキーは未設定で表示しています。保存済み設定は保持しています。\n" + failures.joined(separator: "\n") }
        } catch { errorMessage = "登録失敗: \(error.localizedDescription)" }
    }

    func beginRecording() -> Bool {
        guard !frozen, !recording else { return false }
        recording = true
        recordingOriginal = registry?.shortcuts ?? [:]
        do {
            for command in Self.globalCommands { try registry?.unregister(id: id(command)) }
            return true
        } catch {
            endRecording()
            errorMessage = "記録のためのキー解除に失敗しました: \(error.localizedDescription)"
            return false
        }
    }
    func endRecording() {
        guard recording else { return }
        defer { recording = false; recordingOriginal = nil }
        do { try apply(bindings) }
        catch { errorMessage = "記録後のキー復元に失敗しました: \(error.localizedDescription)" }
    }

    func freeze() { endRecording(); frozen = true }
    func resume() { frozen = false }

    func close() throws { try registry?.close(); registry = nil }

    func change(_ command: AppCommand, to binding: CommandBinding) {
        var next = bindings; next[command] = binding
        do { try apply(next); errorMessage = nil; recording = false; recordingOriginal = nil }
        catch { endRecording(); errorMessage = "変更できません。重複・OS予約キー・他アプリとの競合を確認してください。\(error.localizedDescription)" }
    }
    func reset() {
        do { try apply(AppCommand.defaultBindings); errorMessage = nil }
        catch { errorMessage = "既定値に戻せません: \(error.localizedDescription)" }
    }

    private func id(_ command: AppCommand) -> UInt32 { UInt32(AppCommand.allCases.firstIndex(of: command)! + 1) }
    private func register(_ command: AppCommand, _ shortcut: HotKeyShortcut) throws {
        guard let registry else { throw HotKeyRegistryError.closed }
        try registry.register(id: id(command), shortcut: shortcut) { [weak self] in
            self?.routing.performRegistered(command, shortcut: shortcut)
        }
    }
    private func apply(_ next: [AppCommand: CommandBinding]) throws {
        guard !frozen else { throw EditorWindowError.terminationInProgress }
        try AppCommandRouting.validate(next)
        let globals = Self.globalCommands
        let old = recordingOriginal ?? registry?.shortcuts ?? [:]
        do {
            for command in globals where old[id(command)] != assigned(next[command]) {
                try registry?.unregister(id: id(command))
            }
            for command in globals {
                if case .assigned(let shortcut) = next[command] { try register(command, shortcut) }
            }
        } catch {
            // Roll back to actual previously registered keys; publish any recovery failures honestly.
            var recoveryErrors: [String] = []
            for command in globals {
                do { try registry?.unregister(id: id(command)) } catch { recoveryErrors.append(String(describing: error)) }
            }
            for command in globals {
                if let shortcut = old[id(command)] {
                    do { try register(command, shortcut) } catch { recoveryErrors.append(String(describing: error)) }
                }
            }
            var recovered = bindings
            for command in globals { recovered[command] = registry?.shortcuts[id(command)].map(CommandBinding.assigned) ?? .unassigned }
            try routing.replaceBindings(recovered); bindings = recovered; persist(); didChange?()
            if !recoveryErrors.isEmpty { throw NSError(domain: "getGamen.Shortcuts", code: 1, userInfo: [NSLocalizedDescriptionKey: "登録と復元に失敗。実際に有効なキーを表示しています。\(recoveryErrors.joined(separator: "; "))"]) }
            throw error
        }
        try routing.replaceBindings(next); bindings = next; persist(); didChange?()
    }
    private func assigned(_ binding: CommandBinding?) -> HotKeyShortcut? {
        if case .assigned(let shortcut) = binding { return shortcut }; return nil
    }
    private func persist() {
        let values = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        do { defaults.set(try JSONEncoder().encode(values), forKey: key) }
        catch { errorMessage = "ショートカット設定を保存できません: \(error.localizedDescription)" }
    }

    static func label(_ binding: CommandBinding?) -> String {
        guard case .assigned(let key) = binding else { return "未設定" }
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { key.modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
        let names: [UInt32: String] = [0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 31:"O", 32:"U", 34:"I", 35:"P", 37:"L", 38:"J", 40:"K", 43:",", 45:"N", 46:"M", 47:".", 48:"Tab", 49:"Space", 51:"Delete", 53:"Esc"]
        return symbols + (names[key.keyCode] ?? "Key \(key.keyCode)")
    }
}

@MainActor
struct ShortcutSettingsView: View {
    let settings: ShortcutSettings
    var body: some View {
        Form {
            if let message = settings.errorMessage {
                Section { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section {
                ForEach(AppCommand.available, id: \.self) { command in
                    LabeledContent(command.title) {
                        HStack(spacing: 4) {
                            ShortcutRecorder(identifier: "shortcut-" + command.rawValue, label: ShortcutSettings.label(settings.bindings[command]), begin: { settings.beginRecording() }, end: { settings.endRecording() }) { settings.change(command, to: .assigned($0)) }
                                .frame(width: 165, height: 28)
                            Button { settings.change(command, to: .unassigned) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("ショートカットを解除")
                            .accessibilityLabel("\(command.title)のショートカットを解除")
                        }
                    }
                }
            } footer: {
                Text("記録を押し、使いたいキーを入力してください。キーの位置で記録します。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("すべて既定値に戻す") { settings.reset() }
            }
        }
        .formStyle(.grouped)
        .disabled(settings.frozen)
    }
}

@MainActor
private struct ShortcutRecorder: NSViewRepresentable {
    let identifier: String
    let label: String
    let begin: () -> Bool
    let end: () -> Void
    let recorded: (HotKeyShortcut) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderView { ShortcutRecorderView() }
    func updateNSView(_ view: ShortcutRecorderView, context: Context) { view.setAccessibilityIdentifier(identifier); view.bindingLabel = label; view.recorded = recorded; view.begin = begin; view.end = end; view.isEnabled = context.environment.isEnabled; view.refresh() }
}

@MainActor
final class ShortcutRecorderView: NSButton {
    var bindingLabel = "未設定"
    var recorded: ((HotKeyShortcut) -> Void)?
    var begin: (() -> Bool)?
    var end: (() -> Void)?
    private(set) var isRecording = false
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; target = self; action = #selector(startRecording)
    }
    required init?(coder: NSCoder) { nil }
    func refresh() { title = isRecording ? "キーを入力…" : bindingLabel + " · 記録" }
    @objc private func startRecording() { guard begin?() == true else { return }; isRecording = true; window?.makeFirstResponder(self); refresh() }
    override func resignFirstResponder() -> Bool { if isRecording { end?() }; isRecording = false; refresh(); return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        guard isRecording, !event.isARepeat else { super.keyDown(with: event); return }
        isRecording = false
        recorded?(HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: HotKeyShortcut.carbonModifiers(from: event.modifierFlags)))
        refresh()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }; keyDown(with: event); return true
    }
}
