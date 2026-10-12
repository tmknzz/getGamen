import AppKit
import Carbon

public enum RegionSelectionError: Error, Equatable {
    case busy, invalidShortcut, unavailableScreen, invalidSelection, staleRequest
}

@MainActor
public final class RegionSelectionController {
    @MainActor
    public final class PreparedRegion {
        public let selection: RegionSelection
        public let pixelSize: PixelSize
        public var copiesToClipboard: Bool { resources.copiesToClipboard }
        fileprivate let resources: RegionSelectionResources
        fileprivate init(selection: RegionSelection, pixelSize: PixelSize, resources: RegionSelectionResources) {
            self.selection = selection; self.pixelSize = pixelSize; self.resources = resources
        }
        public func capture(showsCursor: Bool) async throws -> CGImage {
            try await resources.capture(selection: selection, showsCursor: showsCursor)
        }
        public func cancel() { resources.cancel() }
        deinit {
            let resources = resources
            if Thread.isMainThread { MainActor.assumeIsolated { resources.cancelUnusedLease() } }
            else { Task { @MainActor in resources.cancelUnusedLease() } }
        }
    }

    private let captureService: RegionCaptureService
    private let presentation: RegionSelectionPresentation
    private var active: RegionSelectionResources?
    public var didConfirmCapture: (() -> Void)?

    public convenience init(captureService: RegionCaptureService) {
        self.init(captureService: captureService, presentation: .native)
    }
    init(captureService: RegionCaptureService, presentation: RegionSelectionPresentation) {
        self.captureService = captureService; self.presentation = presentation
    }

    public func select(cancelShortcut: HotKeyShortcut?,
                       additionalExclusionWindows: [NSWindow] = [],
                       initialSelection: RegionSelection? = nil) async throws -> PreparedRegion {
        try Task.checkCancellation()
        guard active == nil else { throw RegionSelectionError.busy }
        let allowed = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        guard cancelShortcut == nil || (cancelShortcut!.keyCode <= 127 && cancelShortcut!.modifiers & ~allowed == 0) else {
            throw RegionSelectionError.invalidShortcut
        }
        let resources = RegionSelectionResources(service: captureService, presentation: presentation,
                                                   additional: additionalExclusionWindows, didConfirmCapture: didConfirmCapture) { [weak self] token in
            if self?.active?.token == token { self?.active = nil }
        }
        active = resources
        return try await withTaskCancellationHandler {
            do {
                let prepared = try await resources.select(shortcut: cancelShortcut, initialSelection: initialSelection)
                try Task.checkCancellation()
                guard active?.token == resources.token, resources.isPrepared else { throw CancellationError() }
                return prepared
            } catch {
                resources.cancel(error: error)
                throw error
            }
        } onCancel: {
            Task { @MainActor in resources.cancel() }
        }
    }

    public func cancel() { active?.cancel() }

    /// Waits for the request observed at entry to finish its native/resource cleanup.
    /// Task cancellation does not interrupt this finalizer; subsequent requests are not followed.
    public func waitUntilIdle() async {
        guard let resources = active else { return }
        await resources.waitUntilFinished()
    }
    deinit {
        let resources = active
        if Thread.isMainThread { MainActor.assumeIsolated { resources?.cancel() } }
        else { Task { @MainActor in resources?.cancel() } }
    }
}

/// Holds native windows across awaits independently of controller and returned lease lifetime.
@MainActor
fileprivate final class RegionSelectionResources {
    enum Phase { case starting, selecting, preparing, prepared, capturing, finished }
    let token = UUID()
    private let service: RegionCaptureService
    private let presentation: RegionSelectionPresentation
    private let additional: [NSWindow]
    private let onFinish: (UUID) -> Void
    private var phase: Phase = .starting
    private var cancelled = false
    private var terminalError: Error?
    private var awaitingNative = false
    private var panels: RegionSelectionPanels?
    private var attached = false
    private var buffered: [RegionSelectionEvent] = []
    private var displays: [RegionDisplay] = []
    private var origin: CGPoint?
    private var exclusions: RegionCaptureService.PreparedExclusions?
    private var cancelOwnedService: (@MainActor () -> Void)?
    fileprivate var copiesToClipboard = false
    private var continuation: CheckedContinuation<RegionSelectionController.PreparedRegion, Error>?
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    var isPrepared: Bool { phase == .prepared && !cancelled }

    private let didConfirmCapture: (() -> Void)?

    init(service: RegionCaptureService, presentation: RegionSelectionPresentation,
         additional: [NSWindow], didConfirmCapture: (() -> Void)?, onFinish: @escaping (UUID) -> Void) {
        self.service = service; self.presentation = presentation
        self.additional = additional; self.onFinish = onFinish
        self.didConfirmCapture = didConfirmCapture
    }

    func select(shortcut: HotKeyShortcut?, initialSelection: RegionSelection?) async throws -> RegionSelectionController.PreparedRegion {
        do {
            try check()
            guard service.requestAuthorizationForUserAction() else { throw RegionCaptureError.permissionRequired }
            awaitingNative = true
            do { displays = try await service.snapshot() }
            catch { awaitingNative = false; throw preferred(error) }
            awaitingNative = false
            try check()
            guard let first = displays.first else { throw RegionSelectionError.unavailableScreen }
            _ = try RegionGeometry.select(drag: first.frame, displays: displays)
            let preset = try initialSelection.map { initial in
                do {
                    let rect = try RegionGeometry.dragRect(for: initial, displays: displays)
                    let plan = try RegionGeometry.plan(selection: initial, displays: displays)
                    return (rect, plan)
                } catch let error as RegionGeometryError { throw PreviousRegionError.reselectionRequired(error) }
            }
            phase = .selecting
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let presented = try presentation.present(displays, shortcut) { [weak self] event in
                        self?.receive(event)
                    }
                    panels = presented
                    attached = true
                    if cancelled || phase == .finished {
                        presented.cancelVisible(); presented.hide(); presented.close()
                        panels = nil
                        return
                    }
                    if let (rect, plan) = preset {
                        origin = CGPoint(x: rect.x, y: rect.y)
                        panels?.update(rect, plan.outputSize)
                        presented.preset(rect)
                    }
                    let events = buffered
                    buffered.removeAll()
                    for event in events { receive(event) }
                } catch { cancel(error: error) }
            }
        } catch {
            let error = preferred(error)
            cancel(error: error)
            throw error
        }
    }

    private func receive(_ event: RegionSelectionEvent) {
        guard !cancelled, phase != .finished else { return }
        if !attached { buffered.append(event); return }
        switch event {
        case .copyRequested:
            if phase == .selecting { copiesToClipboard = true }
        case .cancelled: cancel()
        case .topologyChanged: cancel(error: RegionGeometryError.topologyChanged)
        case .failed(let error): cancel(error: error)
        case .began(let point):
            guard phase == .selecting else { return }
            guard point.x.isFinite, point.y.isFinite else { cancel(error: RegionSelectionError.invalidSelection); return }
            origin = point
            panels?.update(nil, nil)
        case .changed(let point): update(point, ended: false)
        case .ended(let point): update(point, ended: true)
        }
    }

    private func update(_ point: CGPoint, ended: Bool) {
        guard phase == .selecting, let origin else { return }
        guard point.x.isFinite, point.y.isFinite else { cancel(error: RegionSelectionError.invalidSelection); return }
        let drag = RegionRect(x: origin.x, y: origin.y, width: point.x - origin.x, height: point.y - origin.y)
        if drag.width == 0 || drag.height == 0 {
            panels?.update(nil, nil)
            if ended { self.origin = nil }
            return
        }
        do {
            let selection = try RegionGeometry.select(drag: drag, displays: displays)
            let plan = try RegionGeometry.plan(selection: selection, displays: displays)
            panels?.update(drag, plan.outputSize)
            if ended {
                phase = .preparing
                didConfirmCapture?()
                awaitingNative = true
                Task { await prepare(selection: selection, plan: plan) }
            }
        } catch { cancel(error: error) }
    }

    private func prepare(selection: RegionSelection, plan: RegionCapturePlan) async {
        do {
            try check()
            var seen = Set<ObjectIdentifier>()
            let windows = ((panels?.windows ?? []) + additional).filter { seen.insert(ObjectIdentifier($0)).inserted }
            let prepared = try await service.prepareExclusions(windows: windows) { [weak self] cancel in
                guard let self else { cancel(); return }
                self.cancelOwnedService = cancel
                if self.cancelled { cancel() }
            }
            exclusions = prepared
            try check()
            let current = try await service.snapshot()
            try check()
            let ids = Set(selection.displays.map(\.id))
            let oldSelected = displays.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
            let newSelected = current.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
            guard oldSelected == newSelected,
                  try RegionGeometry.plan(selection: selection, displays: current) == plan else {
                throw RegionGeometryError.topologyChanged
            }
            awaitingNative = false
            phase = .prepared
            panels?.hide()
            for window in additional { window.orderOut(nil) }
            let preparedRegion = RegionSelectionController.PreparedRegion(selection: selection,
                pixelSize: plan.outputSize, resources: self)
            let completion = continuation
            continuation = nil
            completion?.resume(returning: preparedRegion)
        } catch {
            awaitingNative = false
            let error = preferred(error)
            cancel(error: error)
        }
    }

    func capture(selection: RegionSelection, showsCursor: Bool) async throws -> CGImage {
        guard isPrepared, let exclusions else { throw RegionSelectionError.staleRequest }
        phase = .capturing
        awaitingNative = true
        return try await withTaskCancellationHandler {
            defer { awaitingNative = false; finish() }
            do {
                try check()
                let image = try await service.capture(selection: selection, exclusions: exclusions, showsCursor: showsCursor)
                try check()
                return image
            } catch { throw preferred(error) }
        } onCancel: {
            Task { @MainActor [self] in cancel() }
        }
    }

    func waitUntilFinished() async {
        guard phase != .finished else { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }

    func cancelUnusedLease() { if phase == .prepared { cancel() } }
    func cancel(error: Error = CancellationError()) {
        guard phase != .finished else { return }
        if !cancelled { terminalError = error }
        cancelled = true
        panels?.cancelVisible()
        panels?.hide()
        cancelOwnedService?()
        let completion = continuation
        continuation = nil
        completion?.resume(throwing: terminalError ?? error)
        if !awaitingNative { finish() }
    }
    private func finish() {
        guard phase != .finished else { return }
        phase = .finished
        cancelOwnedService?()
        cancelOwnedService = nil
        exclusions = nil
        panels?.close()
        panels = nil
        buffered.removeAll()
        onFinish(token)
        let waiters = completionWaiters
        completionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func preferred(_ error: Error) -> Error {
        if Task.isCancelled { return CancellationError() }
        return terminalError ?? error
    }
    private func check() throws {
        try Task.checkCancellation()
        if cancelled || phase == .finished { throw terminalError ?? CancellationError() }
    }
}
