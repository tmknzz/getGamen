import AppIntents
import AppKit
import UniformTypeIdentifiers

@MainActor
enum IntentHost {
    static func readyController() async throws -> ApplicationController {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if let controller = (NSApp.delegate as? GetGamenApplicationDelegate)?.controller {
                return controller
            }
            guard ContinuousClock.now < deadline else { throw CaptureMenuIntentError.applicationUnavailable }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func settleCapture(chooser: CaptureChooserController) async {
        cancelIfSelecting(chooser: chooser)
        await chooser.runtime.waitUntilIdle()
    }

    static func withdraw(operationID: UUID, chooser: CaptureChooserController) {
        guard isSelecting(chooser.runtime) else { return }
        chooser.runtime.cancelCapture(id: operationID)
    }

    private static func cancelIfSelecting(chooser: CaptureChooserController) {
        if isSelecting(chooser.runtime) { chooser.cancel() }
    }

    private static func isSelecting(_ runtime: AppRuntime) -> Bool {
        switch runtime.activity {
        case .selecting, .countdown: return true
        default: return false
        }
    }

    // Capture intents also use openAppWhenRun to reliably bring selection UI forward.
    static func capture(_ mode: CaptureMode) async throws -> Data {
        let controller = try await readyController()
        return try await capture(mode, chooser: controller.chooser,
                                 load: { try await controller.store.load(id: $0).originalData })
    }

    static func capture(_ mode: CaptureMode, chooser: CaptureChooserController,
                        load: (UUID) async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        await settleCapture(chooser: chooser)
        try Task.checkCancellation()
        let operationID: UUID
        do {
            // Shortcuts needs the stored original even when the user confirms with Cmd+C.
            operationID = try chooser.start(mode, allowsCopyOnly: false)
        } catch CaptureOperationError.busy, CaptureOperationError.terminationInProgress {
            throw CaptureIntentError.busy
        }
        // Shortcuts stop/timeout cancels the intent task; withdraw only this intent's untaken capture.
        let result = await withTaskCancellationHandler {
            await chooser.runtime.waitForResult(of: operationID)
        } onCancel: {
            Task { @MainActor in
                withdraw(operationID: operationID, chooser: chooser)
            }
        }
        try Task.checkCancellation()
        let documentID = try captureResult(operationID: operationID,
            outcome: result.outcome, failureMessage: result.failureMessage).get()
        do {
            return try await load(documentID)
        } catch {
            throw CaptureIntentError.failed(error.localizedDescription)
        }
    }

    nonisolated static func captureResult(operationID: UUID, outcome: CaptureDeliveryOutcome?,
                                         failureMessage: String?) -> Result<UUID, CaptureIntentError> {
        guard let outcome, outcome.operationID == operationID else {
            return failureMessage.map { .failure(.failed($0)) } ?? .failure(.cancelled)
        }
        switch outcome.disposition {
        case .exportRequested:
            return .success(outcome.documentID)
        case .retainedAfterCancellation:
            return .failure(.cancelled)
        case .retainedAfterFailure(let message):
            return .failure(.failed(message))
        }
    }
}

struct OpenCaptureMenuIntent: AppIntent {
    static let title: LocalizedStringResource = "撮影メニューを開く"
    static let description = IntentDescription("getGamen の撮影メニューを表示します。")
    // openAppWhenRun=true: 起動していなければアプリを起動し、起動中でも確実に前面化する
    // （macOS 14 の協調的アクティベーションに依存しない）。ショートカット由来の
    // 起動・reopen による撮影の自動再開は GetGamenApp.swift 側で抑制する。
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = try await IntentHost.readyController()
        await IntentHost.settleCapture(chooser: controller.chooser)
        guard controller.routing.isEnabled(.chooser) else {
            throw CaptureMenuIntentError.captureMenuUnavailable
        }
        controller.routing.perform(.chooser)
        return .result()
    }
}

struct CaptureWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "ウインドウを撮影"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let png = try await IntentHost.capture(.window)
        return .result(value: IntentFile(data: png, filename: "getGamen.png", type: .png))
    }
}

struct CaptureRegionIntent: AppIntent {
    static let title: LocalizedStringResource = "範囲を撮影"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let png = try await IntentHost.capture(.region)
        return .result(value: IntentFile(data: png, filename: "getGamen.png", type: .png))
    }
}

struct CapturePreviousIntent: AppIntent {
    static let title: LocalizedStringResource = "前と同じ範囲を撮影"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let png = try await IntentHost.capture(.previous)
        return .result(value: IntentFile(data: png, filename: "getGamen.png", type: .png))
    }
}

enum CaptureIntentError: LocalizedError, Equatable {
    case cancelled, failed(String), busy

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "撮影がキャンセルされました。"
        case .failed(let message):
            return "撮影できませんでした: \(message)"
        case .busy:
            return "別の撮影や終了処理の途中です。終わってから、もう一度実行してください。"
        }
    }
}

private enum CaptureMenuIntentError: LocalizedError {
    case applicationUnavailable
    case captureMenuUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationUnavailable:
            return "getGamen の起動準備が完了していません。起動後にもう一度実行してください。"
        case .captureMenuUnavailable:
            return "撮影メニューを今は開けません。撮影や終了処理が終わってから、もう一度実行してください。"
        }
    }
}

struct GetGamenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCaptureMenuIntent(),
            phrases: ["\(.applicationName)で撮影メニューを開く"],
            shortTitle: "撮影メニュー",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: CaptureWindowIntent(),
            phrases: ["\(.applicationName)でウインドウを撮影"],
            shortTitle: "ウインドウを撮影",
            systemImageName: "macwindow"
        )
        AppShortcut(
            intent: CaptureRegionIntent(),
            phrases: ["\(.applicationName)で範囲を撮影"],
            shortTitle: "範囲を撮影",
            systemImageName: "rectangle.dashed"
        )
        AppShortcut(
            intent: CapturePreviousIntent(),
            phrases: ["\(.applicationName)で前と同じ範囲を撮影"],
            shortTitle: "前と同じ範囲を撮影",
            systemImageName: "arrow.counterclockwise"
        )
    }
}
