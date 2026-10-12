import AppKit

public enum PreviousRegionError: Error, Equatable {
    case missingPrevious, corruptRecord, unsupportedRecordVersion(Int)
    case reselectionRequired(RegionGeometryError), busy, staleRequest
}

@MainActor
public final class PreviousRegionController {
    @MainActor
    public final class CapturedRegion {
        public let image: CGImage
        public let selection: RegionSelection
        public let previousRecordError: Error?
        fileprivate init(image: CGImage, selection: RegionSelection, previousRecordError: Error?) {
            self.image = image; self.selection = selection; self.previousRecordError = previousRecordError
        }
    }

    @MainActor
    public final class PreparedPrevious {
        public let selection: RegionSelection
        public let pixelSize: PixelSize
        fileprivate let resources: PreviousRegionResources
        fileprivate init(selection: RegionSelection, pixelSize: PixelSize, resources: PreviousRegionResources) {
            self.selection = selection; self.pixelSize = pixelSize; self.resources = resources
        }
        public func capture(showsCursor: Bool) async throws -> CapturedRegion {
            try await resources.capturePrevious(selection: selection, showsCursor: showsCursor)
        }
        public func cancel() { resources.cancel() }
        deinit {
            let resources = resources
            if Thread.isMainThread { MainActor.assumeIsolated { resources.cancelUnusedLease() } }
            else { Task { @MainActor in resources.cancelUnusedLease() } }
        }
    }

    private let service: RegionCaptureService
    private let store: PreviousRegionRecordStore
    private var active: PreviousRegionResources?

    public convenience init(captureService: RegionCaptureService, recordURL: URL) throws {
        try self.init(captureService: captureService, recordURL: recordURL, beforeAtomicWrite: {})
    }
    init(captureService: RegionCaptureService, recordURL: URL,
         beforeAtomicWrite: @escaping () throws -> Void) throws {
        service = captureService
        store = try PreviousRegionRecordStore(fileURL: recordURL, beforeAtomicWrite: beforeAtomicWrite)
    }

    public func rememberedSelection() throws -> RegionSelection {
        guard let selection = try store.load() else { throw PreviousRegionError.missingPrevious }
        return selection
    }

    public func preparePrevious(excludingWindows: [NSWindow] = []) async throws -> PreparedPrevious {
        try Task.checkCancellation()
        guard active == nil else { throw PreviousRegionError.busy }
        let resources = reserve()
        return try await withTaskCancellationHandler {
            do {
                let prepared = try await resources.prepare(windows: excludingWindows)
                try Task.checkCancellation()
                guard active?.token == resources.token, resources.isPrepared else { throw CancellationError() }
                return prepared
            } catch {
                resources.cancel()
                throw error
            }
        } onCancel: {
            Task { @MainActor in resources.cancel() }
        }
    }

    public func capture(_ region: RegionSelectionController.PreparedRegion,
                        showsCursor: Bool) async throws -> CapturedRegion {
        try Task.checkCancellation()
        guard active == nil else { throw PreviousRegionError.busy }
        let resources = reserve()
        return try await resources.captureFresh(region, showsCursor: showsCursor)
    }

    public func cancel() { active?.cancel() }

    /// Observes one request. Cancellation of this waiter never skips native cleanup.
    public func waitUntilIdle() async {
        guard let resources = active else { return }
        await resources.waitUntilFinished()
    }

    private func reserve() -> PreviousRegionResources {
        let resources = PreviousRegionResources(service: service, store: store) { [weak self] token in
            if self?.active?.token == token { self?.active = nil }
        }
        active = resources
        return resources
    }

    deinit {
        let resources = active
        if Thread.isMainThread { MainActor.assumeIsolated { resources?.cancel() } }
        else { Task { @MainActor in resources?.cancel() } }
    }
}

@MainActor
fileprivate final class PreviousRegionResources {
    private enum Phase { case preparing, prepared, capturing, finished }
    let token = UUID()
    private let service: RegionCaptureService
    private let store: PreviousRegionRecordStore
    private let onFinish: (UUID) -> Void
    private var phase: Phase = .preparing
    private var cancelled = false
    private var awaitingNative = false
    private var windows: [NSWindow] = []
    private var exclusions: RegionCaptureService.PreparedExclusions?
    private var cancelOwnedService: (@MainActor () -> Void)?
    private var freshRegion: RegionSelectionController.PreparedRegion?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isPrepared: Bool { phase == .prepared && !cancelled }

    init(service: RegionCaptureService, store: PreviousRegionRecordStore, onFinish: @escaping (UUID) -> Void) {
        self.service = service; self.store = store; self.onFinish = onFinish
    }

    func prepare(windows: [NSWindow]) async throws -> PreviousRegionController.PreparedPrevious {
        do {
            try check()
            guard let selection = try store.load() else { throw PreviousRegionError.missingPrevious }
            guard service.requestAuthorizationForUserAction() else { throw RegionCaptureError.permissionRequired }
            var seen = Set<ObjectIdentifier>()
            let uniqueWindows = windows.filter { seen.insert(ObjectIdentifier($0)).inserted }
            self.windows = uniqueWindows
            awaitingNative = true
            let initial = try await service.snapshot()
            try check()
            let initialPlan = try plan(selection, displays: initial)
            let exclusions = try await service.prepareExclusions(windows: uniqueWindows) { [weak self] cancel in
                guard let self else { cancel(); return }
                self.cancelOwnedService = cancel
                if self.cancelled { cancel() }
            }
            self.exclusions = exclusions
            try check()
            let current = try await service.snapshot()
            try check()
            guard try plan(selection, displays: current) == initialPlan else {
                throw PreviousRegionError.reselectionRequired(.topologyChanged)
            }
            awaitingNative = false
            phase = .prepared
            for window in uniqueWindows { window.orderOut(nil) }
            return PreviousRegionController.PreparedPrevious(selection: selection,
                pixelSize: initialPlan.outputSize, resources: self)
        } catch {
            let failure = preferred(error)
            awaitingNative = false
            finish()
            throw failure
        }
    }

    func captureFresh(_ region: RegionSelectionController.PreparedRegion,
                      showsCursor: Bool) async throws -> PreviousRegionController.CapturedRegion {
        freshRegion = region
        phase = .capturing
        awaitingNative = true
        return try await withTaskCancellationHandler {
            defer { awaitingNative = false; finish() }
            do {
                try check()
                let image = try await region.capture(showsCursor: showsCursor)
                try check()
                return remember(image: image, selection: region.selection)
            } catch { throw preferred(error) }
        } onCancel: {
            Task { @MainActor [self] in cancel() }
        }
    }

    func capturePrevious(selection: RegionSelection,
                         showsCursor: Bool) async throws -> PreviousRegionController.CapturedRegion {
        guard isPrepared, let exclusions else { throw PreviousRegionError.staleRequest }
        phase = .capturing
        awaitingNative = true
        return try await withTaskCancellationHandler {
            defer { awaitingNative = false; finish() }
            do {
                try check()
                let image = try await service.capture(selection: selection, exclusions: exclusions, showsCursor: showsCursor)
                try check()
                return remember(image: image, selection: selection)
            } catch { throw preferred(error) }
        } onCancel: {
            Task { @MainActor [self] in cancel() }
        }
    }

    private func remember(image: CGImage, selection: RegionSelection) -> PreviousRegionController.CapturedRegion {
        // Only persistence errors belong here; cancellation/native errors were checked beforehand.
        var failure: Error?
        do { try store.remember(selection) }
        catch { failure = error }
        return PreviousRegionController.CapturedRegion(image: image, selection: selection, previousRecordError: failure)
    }

    private func plan(_ selection: RegionSelection, displays: [RegionDisplay]) throws -> RegionCapturePlan {
        do { return try RegionGeometry.plan(selection: selection, displays: displays) }
        catch let error as RegionGeometryError { throw PreviousRegionError.reselectionRequired(error) }
    }

    func cancelUnusedLease() { if phase == .prepared { cancel() } }
    func cancel() {
        guard phase != .finished else { return }
        cancelled = true
        cancelOwnedService?()
        freshRegion?.cancel()
        if !awaitingNative { finish() }
    }
    func waitUntilFinished() async {
        guard phase != .finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func finish() {
        guard phase != .finished else { return }
        phase = .finished
        cancelOwnedService?()
        cancelOwnedService = nil
        freshRegion?.cancel()
        freshRegion = nil
        exclusions = nil
        windows.removeAll()
        onFinish(token)
        let completed = waiters
        waiters.removeAll()
        for waiter in completed { waiter.resume() }
    }
    private func check() throws {
        try Task.checkCancellation()
        if cancelled || phase == .finished { throw CancellationError() }
    }
    private func preferred(_ error: Error) -> Error {
        cancelled || Task.isCancelled ? CancellationError() : error
    }
}
