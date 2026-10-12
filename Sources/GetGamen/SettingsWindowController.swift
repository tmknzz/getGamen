import AppKit
import SwiftUI
import GetGamenCore

@MainActor
final class SettingsWindowController: NSWindowController {
    init(capture: CaptureSettings, export: ExportSettings, shortcuts: ShortcutSettings, license: LicenseManager) {
        // Standard macOS settings: toolbar panes, and the window title follows the selected pane.
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(String, String, AnyView)] = [
            ("撮影・保存", "camera", AnyView(CaptureExportSettingsView(capture: capture, export: export))),
            ("ショートカット", "keyboard", AnyView(ShortcutSettingsView(settings: shortcuts))),
            ("起動", "power", AnyView(LoginSettingsView())),
            ("ライセンス", "key", AnyView(LicenseSettingsView(license: license)))
        ]
        for (title, symbol, view) in panes {
            let pane = NSHostingController(rootView: view.frame(width: 560, height: 460))
            // The tab controller sizes the window and sets its title from the selected pane.
            pane.sizingOptions = .preferredContentSize
            pane.title = title
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}

@MainActor
struct CaptureExportSettingsView: View {
    let capture: CaptureSettings
    let export: ExportSettings
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("撮影") {
                Picker("撮影タイマー", selection: Binding(get: { capture.snapshot.timerSeconds }, set: { value in
                    attempt { try capture.setTimerSeconds(value) }
                })) {
                    Text("なし").tag(0)
                    ForEach([3, 5, 12], id: \.self) { Text("\($0)秒").tag($0) }
                }
                Toggle("マウスポインターを含める", isOn: Binding(get: { capture.snapshot.showsCursor }, set: { capture.setShowsCursor($0) }))
            }
            Section("自動保存") {
                Picker("既定の形式", selection: Binding(get: { export.snapshot.format }, set: { export.setFormat($0) })) {
                    Text("PNG").tag(ExportFormat.png)
                    Text("PNG8（最大256色）").tag(ExportFormat.png8)
                    Text("JPEG").tag(ExportFormat.jpeg)
                }
                Slider(value: Binding(get: { export.snapshot.jpegQuality }, set: { value in
                    attempt { try export.setJPEGQuality(value) }
                }), in: 0...1) {
                    Text("JPEG品質 \(Int(export.snapshot.jpegQuality * 100))%")
                }
                Text("JPEG品質は撮影保存と一括変換で共用します。透明部分は白になります。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("保存先", value: destinationLabel)
                Button("保存先フォルダを選ぶ…") { chooseFolder() }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped)
    }

    private var destinationLabel: String {
        switch export.snapshot.destination {
        case .defaultFolder(let url), .configuredFolder(let url): return url.path
        case .invalidStoredFolder: return "保存先が無効です。選び直してください。"
        }
    }
    private func attempt(_ change: () throws -> Void) {
        do { try change(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "保存先に設定"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try export.setDestinationFolder(url) }
    }
}

@MainActor
struct LicenseSettingsView: View {
    let license: LicenseManager
    @State private var state = LicenseState.free
    @State private var key = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                LabeledContent("状態", value: stateLabel)
                if state == .licensed {
                    Button("このMacのライセンスを解除") { run {
                        await license.deactivate() ? "ライセンスを解除しました。"
                            : "Lemon Squeezy に接続できなかったため、解除できませんでした。ネットワークを確かめてください。"
                    } }
                } else {
                    TextField("ライセンスキー", text: $key)
                    HStack {
                        Button("有効にする") { run {
                            let result = await license.activate(key: key)
                            if result == .success { key = "" }
                            return activationText(result)
                        } }
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("購入ページを開く…") { NSWorkspace.shared.open(LicenseConfig.purchaseURL) }
                    }
                }
            } header: {
                Text("ライセンス")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("アプリでの撮影・編集は無料です。CLI と MCP からの自動操作には、\(LicenseConfig.trialDays)日間の試用のあとライセンスが必要です。ライセンスの確認のときだけ Lemon Squeezy と通信します。")
                    if let message { Text(message) }
                }
                .foregroundStyle(.secondary)
            }
            .disabled(busy)
        }
        .formStyle(.grouped)
        .onAppear { state = license.state() }
    }

    private var stateLabel: String {
        switch state {
        case .trial(let days): return "試用中（残り\(days)日）"
        case .licensed: return "有効"
        case .free: return "未登録（自動操作は使えません）"
        }
    }

    private func activationText(_ result: LicenseActivationResult) -> String {
        switch result {
        case .success: return "ライセンスを有効にしました。"
        case .invalidKey: return "キーが無効です。入力を確かめてください。"
        case .activationLimitReached: return "このキーは別のMacで使われています。そちらで解除してから試してください。"
        case .offline: return "Lemon Squeezy に接続できませんでした。ネットワークを確かめてください。"
        case .storageFailed: return "ライセンス情報を保存できませんでした。"
        }
    }

    private func run(_ action: @escaping @MainActor () async -> String) {
        busy = true
        Task {
            message = await action()
            state = license.state()
            busy = false
        }
    }
}
