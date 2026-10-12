import AppKit
import GetGamenCore

@MainActor
struct CapturedImage {
    let image: CGImage
    let previousRecordError: Error?
    var selection: RegionSelection? = nil
    var copiesToClipboard = false
}

/// Once-only adaptation of an acquired target. AppRuntime owns the application operation.
@MainActor
final class PreparedCapture {
    private let resources: PreparedCaptureResources

    init(capture: @escaping @MainActor (Bool) async throws -> CapturedImage,
         cancel: @escaping @MainActor () -> Void,
         waitForCleanup: @escaping @MainActor () async -> Void) {
        resources = PreparedCaptureResources(capture: capture, cancel: cancel, cleanup: waitForCleanup)
    }

    func capture(showsCursor: Bool) async throws -> CapturedImage {
        try await resources.capture(showsCursor: showsCursor)
    }

    func cancel() { resources.cancel() }

    func waitForCleanup() async { await resources.waitForCleanup() }

    deinit {
        let resources = resources
        if Thread.isMainThread { MainActor.assumeIsolated { resources.cancelUnused() } }
        else { Task { @MainActor in resources.cancelUnused() } }
    }
}

@MainActor
private final class PreparedCaptureResources {
    private enum Phase { case prepared, capturing, finished }
    private var phase = Phase.prepared
    private var cancelled = false
    private var finishingWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupStarted = false
    private var cleanupFinished = false
    private let captureAction: @MainActor (Bool) async throws -> CapturedImage
    private let cancelAction: @MainActor () -> Void
    private let cleanupAction: @MainActor () async -> Void

    init(capture: @escaping @MainActor (Bool) async throws -> CapturedImage,
         cancel: @escaping @MainActor () -> Void,
         cleanup: @escaping @MainActor () async -> Void) {
        captureAction = capture
        cancelAction = cancel
        cleanupAction = cleanup
    }

    func capture(showsCursor: Bool) async throws -> CapturedImage {
        guard phase == .prepared else { throw CaptureOperationError.staleRequest }
        if Task.isCancelled { cancel(); throw CancellationError() }
        phase = .capturing
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let image = try await captureAction(showsCursor)
                guard !cancelled else { throw CancellationError() }
                try Task.checkCancellation()
                finish()
                return image
            } catch {
                let wasCancelled = cancelled || Task.isCancelled
                cancel()
                finish()
                if wasCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancelUnused() { if phase == .prepared { cancel() } }

    func cancel() {
        guard phase != .finished, !cancelled else { return }
        cancelled = true
        cancelAction()
        // An in-flight native await retains the target and must settle before cleanup completes.
        if phase == .prepared { finish() }
    }

    private func finish() {
        guard phase != .finished else { return }
        phase = .finished
        let waiters = finishingWaiters
        finishingWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForCleanup() async {
        if phase != .finished {
            await withCheckedContinuation { finishingWaiters.append($0) }
        }
        if cleanupFinished { return }
        if cleanupStarted {
            await withCheckedContinuation { cleanupWaiters.append($0) }
            return
        }
        cleanupStarted = true
        await cleanupAction()
        cleanupFinished = true
        let waiters = cleanupWaiters
        cleanupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Its controllers are exclusively owned by one serialized AppRuntime.
@MainActor
struct CapturePreparation {
    private let windowService: WindowCaptureService
    private let regionController: RegionSelectionController
    private let previousController: PreviousRegionController
    private let didConfirmCapture: @MainActor () -> Void
    private let beforeRegionCleanup: @MainActor () -> Void

    init(windowService: WindowCaptureService, regionController: RegionSelectionController,
         previousController: PreviousRegionController,
         didConfirmCapture: @escaping @MainActor () -> Void = {},
         beforeRegionCleanup: @escaping @MainActor () -> Void = {}) {
        self.didConfirmCapture = didConfirmCapture
        windowService.didConfirmCapture = didConfirmCapture
        regionController.didConfirmCapture = didConfirmCapture
        self.windowService = windowService
        self.regionController = regionController
        self.previousController = previousController
        self.beforeRegionCleanup = beforeRegionCleanup
    }

    func prepare(mode: CaptureMode, windows: [NSWindow],
                 cancelShortcut: HotKeyShortcut?, confirmsPreviousCapture: Bool = true,
                 reviewsPrevious: Bool = false) async throws -> PreparedCapture {
        try Task.checkCancellation()
        let prepared: PreparedCapture
        switch mode {
        case .scroll:
            throw CaptureOperationError.unsupportedMode(.scroll)
        case .window:
            let ids = try Self.windowIDs(windows)
            let selection = try await windowService.selectWindow(excludingWindowIDs: ids)
            prepared = PreparedCapture(capture: { [windowService] cursor in
                CapturedImage(image: try await windowService.capture(selection, showsCursor: cursor),
                              previousRecordError: nil, copiesToClipboard: selection.copiesToClipboard)
            }, cancel: { [windowService] in
                windowService.cancel()
            }, waitForCleanup: {
                // T11 capture awaits native work inline; the wrapper waits for that call first.
                withExtendedLifetime(windows) {}
            })
        case .region:
            prepared = try await prepareRegion(windows: windows, cancelShortcut: cancelShortcut,
                                               initialSelection: nil)
        case .previous where reviewsPrevious:
            let initial = try previousController.rememberedSelection()
            prepared = try await prepareRegion(windows: windows, cancelShortcut: cancelShortcut,
                                               initialSelection: initial)
        case .previous:
            if confirmsPreviousCapture { didConfirmCapture() }
            let previous: PreviousRegionController.PreparedPrevious
            do {
                previous = try await previousController.preparePrevious(excludingWindows: windows)
            } catch {
                if error as? PreviousRegionError != .busy { await previousController.waitUntilIdle() }
                try Task.checkCancellation()
                throw error
            }
            prepared = PreparedCapture(capture: { cursor in
                let result = try await previous.capture(showsCursor: cursor)
                return CapturedImage(image: result.image, previousRecordError: result.previousRecordError, selection: result.selection)
            }, cancel: {
                previous.cancel()
            }, waitForCleanup: { [previousController] in
                await previousController.waitUntilIdle()
                withExtendedLifetime(windows) {}
            })
        }
        // A returned target was acquired; cancellation here can clean only that target.
        if Task.isCancelled {
            prepared.cancel()
            await prepared.waitForCleanup()
            throw CancellationError()
        }
        return prepared
    }

    private func prepareRegion(windows: [NSWindow], cancelShortcut: HotKeyShortcut?,
                               initialSelection: RegionSelection?) async throws -> PreparedCapture {
        let region: RegionSelectionController.PreparedRegion
        do {
            region = try await regionController.select(cancelShortcut: cancelShortcut,
                                                       additionalExclusionWindows: windows,
                                                       initialSelection: initialSelection)
        } catch {
            // Only this controller's pre-reservation busy error means no holder was acquired.
            if error as? RegionSelectionError != .busy {
                // Acknowledges select returning; never replaces the actual cleanup barrier.
                beforeRegionCleanup()
                await regionController.waitUntilIdle()
            }
            try Task.checkCancellation()
            throw error
        }
        var waitForPrevious = false
        return PreparedCapture(capture: { [previousController] cursor in
            waitForPrevious = true
            do {
                let result = try await previousController.capture(region, showsCursor: cursor)
                return CapturedImage(image: result.image, previousRecordError: result.previousRecordError, selection: result.selection,
                                     copiesToClipboard: region.copiesToClipboard)
            } catch {
                // Busy rejected before T13 adoption: never wait on that foreign holder.
                if error as? PreviousRegionError == .busy { waitForPrevious = false }
                throw error
            }
        }, cancel: {
            region.cancel()
        }, waitForCleanup: { [regionController, previousController] in
            await regionController.waitUntilIdle()
            if waitForPrevious { await previousController.waitUntilIdle() }
            withExtendedLifetime(windows) {}
        })
    }

    private static func windowIDs(_ windows: [NSWindow]) throws -> [Int] {
        var objects = Set<ObjectIdentifier>()
        var identifiers = Set<Int>()
        var result: [Int] = []
        for window in windows {
            let id = window.windowNumber
            guard id > 0, UInt32(exactly: id) != nil else { throw CaptureOperationError.invalidWindow }
            guard objects.insert(ObjectIdentifier(window)).inserted, identifiers.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }
}
