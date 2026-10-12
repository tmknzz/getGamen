import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class LoginSettings {
    private(set) var enabled = false
    private(set) var message = ""
    private(set) var busy = false
    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        switch status {
        case .enabled: message = "ログイン時に起動します。"
        case .requiresApproval: message = "システム設定でログイン項目の許可が必要です。"
        case .notRegistered: message = "ログイン時には起動しません。"
        case .notFound: message = "アプリが見つかりません。getGamen.appから起動してください。"
        @unknown default: message = "ログイン項目の状態を確認できません。"
        }
    }
    func change(_ value: Bool) {
        guard !busy else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                if value { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                refresh()
            } catch { refresh(); message = "設定を変更できません: \(error.localizedDescription)" }
        }
    }
}

@MainActor
struct LoginSettingsView: View {
    @State private var settings = LoginSettings()
    var body: some View {
        Form {
            Section {
                Toggle("ログイン時にgetGamenを起動", isOn: Binding(get: { settings.enabled }, set: { settings.change($0) }))
                HStack {
                    Button("ログイン項目の設定を開く…") { SMAppService.openSystemSettingsLoginItems() }
                    Spacer()
                    Button { settings.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("状態を更新")
                        .accessibilityLabel("状態を更新")
                }
            } header: {
                Text("ログイン時の起動")
            } footer: {
                Text(settings.message).foregroundStyle(.secondary)
            }
            .disabled(settings.busy)
        }
        .formStyle(.grouped)
        .onAppear { settings.refresh() }
    }
}
