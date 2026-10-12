import AppKit
import Observation
import GetGamenCore

enum CaptureMode: String, CaseIterable {
    case window, region, previous, scroll
}

enum CaptureActivity: Equatable {
    case idle, selecting, countdown(Int), capturing, delivering, cancelling
}

enum CaptureOperationError: Error, Equatable {
    case busy, unsupportedMode(CaptureMode), staleRequest, invalidWindow, terminationInProgress
}

@MainActor
struct CaptureIntent {
    let id: UUID
    let mode: CaptureMode
    var capture: CaptureSettingsSnapshot
    let export: ExportSettingsSnapshot
    let cancelShortcut: HotKeyShortcut?
    var allowsCopyOnly = true
}

/// The preparation's concrete controllers are exclusively owned by this runtime.
/// An operation remains reserved until its native cleanup, including cancelled selection, finishes.
@MainActor
@Observable
final class AppRuntime {
    private(set) var activity: CaptureActivity = .idle {
        didSet { activityDidChange?(activity) }
    }
    /// One presentation owner; invoked synchronously before capture work can advance.
    @ObservationIgnored var activityDidChange: (@MainActor (CaptureActivity) -> Void)?
    private(set) var failureMessage: String?
    private(set) var failureNeedsReselection = false
    private(set) var previousRecordWarning: String?
    private(set) var isTerminationPending = false

    let captureSettings: CaptureSettings
    private let exportSettings: ExportSettings
    @ObservationIgnored private let editorWindows: EditorWindowCoordinator
    var cancelShortcut: HotKeyShortcut?
    private let prepare: @MainActor (CaptureMode, [NSWindow], HotKeyShortcut?) async throws -> PreparedCapture
    private let wait: @MainActor (Int, @escaping @MainActor (Int) -> Void) async throws -> Void
    private let delivery: Delivery
    @ObservationIgnored private var active: CaptureOperation?

    private enum Delivery {
        case injected(@MainActor (CapturedImage, CaptureIntent) async throws -> Void)
        case stored(CapturedDocumentHandoff)
    }

    var deliveryOutcome: CaptureDeliveryOutcome? {
        guard case .stored(let handoff) = delivery else { return nil }
        return handoff.outcome
    }

    convenience init(
        captureSettings: CaptureSettings, exportSettings: ExportSettings,
        editorWindows: EditorWindowCoordinator,
        cancelShortcut: HotKeyShortcut?, preparation: CapturePreparation,
        didCapture: @escaping @MainActor (CapturedImage, CaptureIntent) async throws -> Void
    ) {
        self.init(captureSettings: captureSettings, exportSettings: exportSettings,
                  editorWindows: editorWindows,
                  cancelShortcut: cancelShortcut, prepare: { mode, windows, shortcut in
            try await preparation.prepare(mode: mode, windows: windows, cancelShortcut: shortcut)
        }, wait: { seconds, onRemaining in
            try await CaptureCountdown().wait(seconds: seconds, onRemaining: onRemaining)
        }, didCapture: didCapture)
    }

    convenience init(
        captureSettings: CaptureSettings, exportSettings: ExportSettings,
        editorWindows: EditorWindowCoordinator,
        cancelShortcut: HotKeyShortcut?,
        prepare: @escaping @MainActor (CaptureMode, [NSWindow], HotKeyShortcut?) async throws -> PreparedCapture,
        wait: @escaping @MainActor (Int, @escaping @MainActor (Int) -> Void) async throws -> Void,
        didCapture: @escaping @MainActor (CapturedImage, CaptureIntent) async throws -> Void
    ) {
        self.init(captureSettings: captureSettings, exportSettings: exportSettings,
                  editorWindows: editorWindows, cancelShortcut: cancelShortcut,
                  prepare: prepare, wait: wait, delivery: .injected(didCapture))
    }

    convenience init(
        captureSettings: CaptureSettings, exportSettings: ExportSettings,
        cancelShortcut: HotKeyShortcut?,
        prepare: @escaping @MainActor (CaptureMode, [NSWindow], HotKeyShortcut?) async throws -> PreparedCapture,
        wait: @escaping @MainActor (Int, @escaping @MainActor (Int) -> Void) async throws -> Void = {
            seconds, onRemaining in
            try await CaptureCountdown().wait(seconds: seconds, onRemaining: onRemaining)
        },
        handoff: CapturedDocumentHandoff
    ) {
        self.init(captureSettings: captureSettings, exportSettings: exportSettings,
                  editorWindows: handoff.editorWindows, cancelShortcut: cancelShortcut,
                  prepare: prepare, wait: wait, delivery: .stored(handoff))
    }

    private init(
        captureSettings: CaptureSettings, exportSettings: ExportSettings,
        editorWindows: EditorWindowCoordinator, cancelShortcut: HotKeyShortcut?,
        prepare: @escaping @MainActor (CaptureMode, [NSWindow], HotKeyShortcut?) async throws -> PreparedCapture,
        wait: @escaping @MainActor (Int, @escaping @MainActor (Int) -> Void) async throws -> Void,
        delivery: Delivery
    ) {
        self.captureSettings = captureSettings
        self.exportSettings = exportSettings
        self.editorWindows = editorWindows
        self.cancelShortcut = cancelShortcut
        self.prepare = prepare
        self.wait = wait
        self.delivery = delivery
    }

    func openEditor(documentID: UUID,
                    initialSettings: ExportSettingsSnapshot? = nil) async throws -> EditorSession {
        try await editorWindows.openEditor(documentID: documentID, initialSettings: initialSettings)
    }

    var didCompleteRegion: (@MainActor (RegionSelection) -> Void)?
    var didConfirmImmediately: (@MainActor () -> Void)?
    var didFinishCountdown: (@MainActor () -> Void)?
    var didAcquireImage: (@MainActor () -> Void)?

    /// Adjust the pending delay without destroying the user's selection.
    func confirmCapture() {
        guard let active, !active.cancelRequested, activity == .selecting, active.confirmedTimerSeconds == nil else { return }
        let seconds = active.timerOverride ?? active.intent.capture.timerSeconds
        active.confirmedTimerSeconds = seconds
        if seconds == 0 { didConfirmImmediately?() }
    }

    func updateSelectionTimer(_ seconds: Int) {
        guard activity == .selecting, let active, !active.cancelRequested,
              [0, 3, 5, 12].contains(seconds) else { return }
        active.timerOverride = seconds
    }

    @discardableResult
    func startCapture(_ mode: CaptureMode, exclusionWindows: [NSWindow] = [], allowsCopyOnly: Bool = true) throws -> UUID {
        guard !isTerminationPending else { throw CaptureOperationError.terminationInProgress }
        guard active == nil else { throw CaptureOperationError.busy }
        guard mode != .scroll else { throw CaptureOperationError.unsupportedMode(.scroll) }
        if case .stored(let handoff) = delivery { handoff.resetOutcome() }
        let intent = CaptureIntent(id: UUID(), mode: mode, capture: captureSettings.snapshot,
                                   export: exportSettings.snapshot, cancelShortcut: cancelShortcut, allowsCopyOnly: allowsCopyOnly)
        let operation = CaptureOperation(intent: intent, windows: exclusionWindows)
        active = operation
        failureMessage = nil
        failureNeedsReselection = false
        previousRecordWarning = nil
        activity = .selecting

        // Copy dependencies before starting. Awaiting work retains its resources, not the runtime.
        let prepare = prepare
        let wait = wait
        let delivery = delivery
        operation.task = Task { @MainActor [weak self, operation] in
            var failure: Error?
            var completedSelection: RegionSelection?
            do {
                guard self?.mayProceed(operation) == true else { throw CancellationError() }
                let target = try await prepare(intent.mode, operation.windows, intent.cancelShortcut)
                // Retain even a late target so cancellation cannot abandon its cleanup.
                operation.target = target
                guard self?.mayProceed(operation) == true else { throw CancellationError() }
                var intent = intent
                intent.capture = CaptureSettingsSnapshot(
                    timerSeconds: operation.confirmedTimerSeconds ?? operation.timerOverride ?? intent.capture.timerSeconds,
                    showsCursor: intent.capture.showsCursor)
                operation.countdownActive = true
                try await wait(intent.capture.timerSeconds) { [weak self, weak operation] remaining in
                    guard let operation, operation.countdownActive,
                          self?.mayProceed(operation) == true else { return }
                    self?.activity = .countdown(remaining)
                }
                operation.countdownActive = false
                guard self?.mayProceed(operation) == true else { throw CancellationError() }
                if intent.capture.timerSeconds > 0 { self?.didFinishCountdown?() }
                self?.activity = .capturing
                guard self?.mayProceed(operation) == true else { throw CancellationError() }
                let captured = try await target.capture(showsCursor: intent.capture.showsCursor)
                guard self?.mayProceed(operation) == true else { throw CancellationError() }
                self?.didAcquireImage?()
                completedSelection = captured.selection
                self?.previousRecordWarning = captured.previousRecordError?.localizedDescription
                self?.activity = .delivering
                guard self?.mayProceed(operation) == true else { throw CancellationError() }
                switch delivery {
                case .injected(let action): try await action(captured, intent)
                case .stored(let handoff): try await handoff.accept(captured, intent: intent)
                }
                guard self?.mayProceed(operation) == true else { throw CancellationError() }
            } catch {
                failure = error
            }

            operation.countdownActive = false
            if failure != nil { operation.target?.cancel() }
            if let target = operation.target { await target.waitForCleanup() }
            // Keep the reservation until this point, even if cancellation returned early upstream.
            if self?.active?.intent.id == intent.id {
                if !operation.cancelRequested, !Task.isCancelled,
                   let failure, !(failure is CancellationError) {
                    self?.recordFailure(failure)
                }
                // Record this operation's result before a new capture can reset the shared state.
                operation.outcome = self?.deliveryOutcome
                operation.failureMessage = self?.failureMessage
                self?.active = nil
                self?.activity = .idle
                if failure == nil, !operation.cancelRequested, !Task.isCancelled,
                   self?.isTerminationPending == false, let completedSelection {
                    self?.didCompleteRegion?(completedSelection)
                }
            }
            operation.finish()
        }
        return intent.id
    }

    func cancelCapture() {
        guard let operation = active, !operation.cancelRequested else { return }
        activity = .cancelling
        operation.cancel()
    }

    /// Cancels only the given operation, never a capture started after it.
    func cancelCapture(id: UUID) {
        guard active?.intent.id == id else { return }
        cancelCapture()
    }

    func beginTermination() {
        isTerminationPending = true
        cancelCapture()
    }

    func endTermination() { isTerminationPending = false }

    private func recordFailure(_ error: Error) {
        if let previous = error as? PreviousRegionError {
            switch previous {
            case .missingPrevious, .corruptRecord, .unsupportedRecordVersion, .reselectionRequired:
                failureNeedsReselection = true
                failureMessage = "前回の範囲を使用できません。範囲を選び直してください。"
                return
            default: break
            }
        }
        if error as? RegionCaptureError == .permissionRequired {
            failureMessage = "画面収録の許可が必要です。システム設定でgetGamenを許可してください。"
        } else {
            failureMessage = error.localizedDescription
        }
    }

    /// Noncancellable observation of the operation present at entry; never follows a new capture.
    func waitUntilIdle() async {
        guard let operation = active else { return }
        await operation.waitUntilFinished()
    }

    /// Noncancellable wait for the given operation; returns its own result even if
    /// another capture has started since. Returns no result for an inactive operation.
    func waitForResult(of id: UUID) async -> (outcome: CaptureDeliveryOutcome?, failureMessage: String?) {
        guard let operation = active, operation.intent.id == id else { return (nil, nil) }
        await operation.waitUntilFinished()
        return (operation.outcome, operation.failureMessage)
    }

    private func mayProceed(_ operation: CaptureOperation) -> Bool {
        active?.intent.id == operation.intent.id && !operation.cancelRequested && !Task.isCancelled
    }

    deinit {
        let operation = active
        if Thread.isMainThread { MainActor.assumeIsolated { operation?.cancel() } }
        else { Task { @MainActor in operation?.cancel() } }
    }
}

/// Resource lifetime only, not a second preparation or capture pipeline.
@MainActor
private final class CaptureOperation {
    let intent: CaptureIntent
    let windows: [NSWindow]
    var task: Task<Void, Never>?
    var target: PreparedCapture?
    var cancelRequested = false
    var countdownActive = false
    var confirmedTimerSeconds: Int?
    var timerOverride: Int?
    var outcome: CaptureDeliveryOutcome?
    var failureMessage: String?
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(intent: CaptureIntent, windows: [NSWindow]) {
        self.intent = intent
        self.windows = windows
    }

    func cancel() {
        guard !finished, !cancelRequested else { return }
        cancelRequested = true
        countdownActive = false
        task?.cancel()
        target?.cancel()
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        target = nil
        task = nil
        let completed = waiters
        waiters.removeAll()
        for waiter in completed { waiter.resume() }
    }
}
