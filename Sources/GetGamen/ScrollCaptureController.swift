import AppKit
import Observation
import SwiftUI
import GetGamenCore

@MainActor
@Observable
final class ScrollCaptureController: NSObject, NSWindowDelegate {
    private let soundTiming: ScrollCaptureSoundTiming
    private let countdownSound: @MainActor () -> Void
    private let accumulator: ScrollAccumulator
    private let preparation: CapturePreparation
    private let captureSettings: CaptureSettings
    private let exportSettings: ExportSettings
    private let store: DocumentStore
    private let editors: EditorWindowCoordinator
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var restored = false
    private var dismissed = false
    private var hasFrame = false
    private(set) var frozen = false
    private(set) var deliveryFailed = false
    private(set) var running = false
    private(set) var busy = false
    private(set) var message = "重なりを残しながら手動で下へスクロールしてください。"
    private(set) var dimensions = ""
    var mayStart: () -> Bool = { true }
    var willStartCapture: (@MainActor () -> Void)?
    var didAcquireImage: (() -> Void)?
    var cancelShortcut: HotKeyShortcut?
    var hasPendingWork: Bool { busy }
    var canFinish: Bool { hasFrame && !busy && !frozen }
    var isActive: Bool { running || busy }
    var shouldRestoreWindow: Bool { !dismissed && !frozen }
    var captureExclusionWindows: [NSWindow] { window.map { [$0] } ?? [] }

    init(root: URL, capture: CaptureSettings, export: ExportSettings, store: DocumentStore,
         editors: EditorWindowCoordinator, didConfirmCapture: @escaping @MainActor () -> Void = {}) throws {
        let timing = ScrollCaptureSoundTiming()
        soundTiming = timing
        countdownSound = didConfirmCapture
        accumulator = ScrollAccumulator(checkpointURL: root.appendingPathComponent("scroll-checkpoint.json"))
        let service = RegionCaptureService()
        preparation = CapturePreparation(windowService: WindowCaptureService(),
            regionController: RegionSelectionController(captureService: service),
            previousController: try PreviousRegionController(captureService: service, recordURL: root.appendingPathComponent("scroll-region.json")),
            didConfirmCapture: {
                if timing.timerSeconds == 0 { didConfirmCapture() }
            })
        captureSettings = capture; exportSettings = export; self.store = store; self.editors = editors
        super.init()
    }

    func present() {
        guard !frozen else { return }
        dismissed = false
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "getGamen — スクロール撮影"; window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ScrollCaptureView(controller: self))
            window.delegate = self; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate()
        guard !restored, !busy else { return }
        busy = true
        task = Task { @MainActor in
            do {
                if let snapshot = try await accumulator.restore() {
                    update(snapshot); message = "前回の撮影途中を保持しています。最後につながった画面位置へ戻して再開できます。"
                }
                restored = true
            } catch { message = "撮影途中の復元に失敗しました。データは保持しています。\(error.localizedDescription)" }
            busy = false; task = nil
        }
    }

    func revealWindowForCapture() {
        dismissed = false
        willStartCapture?()
        window?.orderFrontRegardless()
    }

    func startOrResume() {
        guard !frozen, !busy, restored, mayStart() else { return }
        revealWindowForCapture()
        running = true; busy = true
        let capture = captureSettings.snapshot, shortcut = cancelShortcut
        soundTiming.timerSeconds = capture.timerSeconds
        let fresh = !hasFrame
        task = Task { @MainActor in
            defer { running = false; busy = false; task = nil; if shouldRestoreWindow { window?.orderFrontRegardless() } }
            do {
                var first = true
                while running {
                    try Task.checkCancellation()
                    let windows = captureExclusionWindows
                    let target = try await preparation.prepare(mode: first && fresh ? .region : .previous,
                                                               windows: windows, cancelShortcut: shortcut, confirmsPreviousCapture: first)
                    let captured: CapturedImage
                    do {
                        if first {
                            try await CaptureCountdown().wait(seconds: capture.timerSeconds) { seconds in
                                self.message = seconds > 0 ? "撮影まで \(seconds) 秒" : "撮影を開始します…"
                            }
                        }
                        try Task.checkCancellation()
                        if first, capture.timerSeconds > 0 { countdownSound() }
                        willStartCapture?()
                        captured = try await target.capture(showsCursor: capture.showsCursor)
                        try Task.checkCancellation()
                        didAcquireImage?()
                        await target.waitForCleanup()
                        if shouldRestoreWindow { window?.orderFrontRegardless() }
                    } catch {
                        target.cancel(); await target.waitForCleanup()
                        throw error
                    }
                    try Task.checkCancellation()
                    let result = try await accumulator.accept(captured.image)
                    if let snapshot = try await accumulator.snapshot() { update(snapshot) }
                    if let error = captured.previousRecordError {
                        message = "範囲情報の保存に失敗しました。撮影済み画像は保持しています。\(error.localizedDescription)"
                        return
                    }
                    switch result {
                    case .rejected(let reason):
                        message = "重なりを確定できないため停止しました（\(reason)）。最後につながった位置へ戻し、小さく下へスクロールして再開してください。"
                        return
                    case .started, .appended: message = "撮影中。重なりを残しながら手動で下へスクロールしてください。"
                    case .unchanged: break
                    }
                    first = false
                    try await Task.sleep(for: .milliseconds(900))
                }
            } catch is CancellationError {
                message = "一時停止しました。撮影済み部分は保持しています。"
            } catch {
                message = "撮影を停止しました。撮影済み部分は保持しています。\(error.localizedDescription)"
            }
        }
    }

    func pause() { running = false; task?.cancel() }
    func togglePause() { if running { pause() } else { startOrResume() } }
    func finish() {
        guard canFinish else { return }
        busy = true; deliveryFailed = false
        let snapshotSettings = exportSettings.snapshot
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                guard let snapshot = try await accumulator.snapshot() else { return }
                let document = try await store.create(original: snapshot.png, pixelSize: PixelSize(width: snapshot.width, height: snapshot.height))
                // A stored original stays until its editor closes or the next launch, even if cleanup or opening fails.
                do { try await accumulator.clear(); hasFrame = false; dimensions = "" }
                catch { deliveryFailed = true; message = "結合した画像を保存しましたが、途中データの削除に失敗しました。\(error.localizedDescription)"; return }
                message = "結合した画像を保存しました。"
                let session = try await editors.openEditor(documentID: document.documentID, initialSettings: snapshotSettings)
                guard !session.isTerminationPending else { throw EditorWindowError.terminationInProgress }
                session.requestCaptureExport(using: snapshotSettings)
                dismissed = true
                window?.orderOut(nil)
            } catch { deliveryFailed = true; message = "完了処理に失敗しました。\(error.localizedDescription)" }
        }
    }
    private func update(_ snapshot: ScrollAccumulator.Snapshot) {
        hasFrame = true
        dimensions = "\(snapshot.width) × \(snapshot.height) px · \(snapshot.frames)枚"
    }
    func freeze() { frozen = true; if running { pause() } }
    func resume() {
        frozen = false
        if shouldRestoreWindow, let window, !window.isVisible { window.orderFrontRegardless() }
    }
    func waitUntilIdle() async { await task?.value }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissed = true
        if running { pause() }
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private struct ScrollCaptureView: View {
    let controller: ScrollCaptureController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(controller.message).textSelection(.enabled)
            Text(controller.dimensions).monospacedDigit()
            HStack {
                if controller.running { Button("一時停止") { controller.pause() } }
                else { Button("開始／再開") { controller.startOrResume() }.disabled(controller.busy) }
                Button("完了して加工") { controller.finish() }.disabled(!controller.canFinish)
            }
            Text("固定ヘッダー・動く内容・繰り返し模様などで結合が不確かな場合は停止します。撮影途中は終了後も保持します。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 380).disabled(controller.frozen)
    }
}

@MainActor
private final class ScrollCaptureSoundTiming {
    var timerSeconds = 0
}
