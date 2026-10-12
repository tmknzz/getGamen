import Foundation

public struct ExportRequest: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let slot: ExportSlot
    public let createdAt: Date
    public let destinationFolder: URL
    public let encode: @Sendable () async throws -> Data

    public init(documentID: UUID, revision: UInt64, slot: ExportSlot,
                createdAt: Date, destinationFolder: URL,
                encode: @escaping @Sendable () async throws -> Data) {
        self.documentID = documentID
        self.revision = revision
        self.slot = slot
        self.createdAt = createdAt
        self.destinationFolder = destinationFolder
        self.encode = encode
    }
}

public enum ExportStatus: Equatable, Sendable {
    case idle
    case saving(request: UInt64, revision: UInt64)
    case saved(request: UInt64, revision: UInt64, url: URL)
    case failed(request: UInt64, revision: UInt64, message: String)
}

/// Owns synchronous publication; asynchronous encoders never receive the writer.
public actor AutomaticExportCoordinator {
    private var writer: OwnedExportWriter
    private var lastRequest: UInt64
    private var latest: [UUID: UInt64] = [:]
    private var revisions: [UUID: UInt64] = [:]
    private var statuses: [UUID: ExportStatus] = [:]
    private var workers: [UInt64: Task<Void, Never>] = [:]
    private var subscribers: [UUID: [UUID: AsyncStream<ExportStatus>.Continuation]] = [:]
    private var settlementWaiters: [UUID: [UUID: CheckedContinuation<ExportStatus, Error>]] = [:]
    private var workerWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    /// `discardsPreviousReceipts` recovers, then forgets, the export history an earlier run left behind.
    public init(receiptsRoot: URL, discardsPreviousReceipts: Bool = false) throws {
        let writer = try OwnedExportWriter(receiptsRoot: receiptsRoot)
        if discardsPreviousReceipts { try writer.discardReceipts() }
        self.lastRequest = try writer.maximumRequestNumber()
        self.writer = writer
    }

    deinit {
        for task in workers.values { task.cancel() }
        for group in subscribers.values {
            for continuation in group.values { continuation.finish() }
        }
        for group in settlementWaiters.values {
            for continuation in group.values { continuation.resume(throwing: CancellationError()) }
        }
        for group in workerWaiters.values {
            for continuation in group { continuation.resume() }
        }
    }

    @discardableResult
    public func submit(_ request: ExportRequest) throws -> UInt64 {
        guard request.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExportWriteError.invalidData
        }
        guard request.destinationFolder.isFileURL else { throw ExportWriteError.destinationUnavailable }
        let persisted = try writer.maximumDocumentRevision(documentID: request.documentID)
        let known = [persisted, revisions[request.documentID]].compactMap { $0 }.max()
        if let known, request.revision < known { throw ExportWriteError.staleRequest }
        let next = lastRequest.addingReportingOverflow(1)
        guard !next.overflow else { throw ExportWriteError.sequenceOverflow }
        let id = next.partialValue
        lastRequest = id
        if let superseded = latest[request.documentID] { workers[superseded]?.cancel() }
        latest[request.documentID] = id
        revisions[request.documentID] = request.revision
        transition(.saving(request: id, revision: request.revision), documentID: request.documentID)

        // Do not promote weak self until encoding has finished: an encoder may await indefinitely.
        workers[id] = Task.detached { [weak self, request] in
            let result: Result<Data, Error>
            do { result = .success(try await request.encode()) }
            catch { result = .failure(error) }
            await self?.completed(request, id: id, result: result)
        }
        return id
    }

    public func status(documentID: UUID) -> ExportStatus {
        statuses[documentID] ?? .idle
    }

    /// Observe exactly the encoders present at entry, including superseded workers.
    /// Call after freezing producers and draining their submission queues.
    /// Cancelling the observer never cancels a write or reports premature completion.
    public func waitForCurrentWorkers() async -> [UUID: ExportStatus] {
        await waitForCurrentWorkers(onWaiting: { _ in })
    }

    func waitForCurrentWorkers(onWaiting: @Sendable (UInt64) -> Void) async -> [UUID: ExportStatus] {
        let snapshot = Array(workers.keys)
        for request in snapshot {
            await waitForEncodingCompletion(request: request, onWaiting: { onWaiting(request) })
        }
        return statuses
    }

    public func existing(documentID: UUID, slot: ExportSlot) throws -> PublishedExport? {
        try writer.existing(documentID: documentID, slot: slot)
    }

    public func updates(documentID: UUID) -> AsyncStream<ExportStatus> {
        let subscriptionID = UUID()
        let pair = AsyncStream<ExportStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(documentID: documentID, subscriptionID: subscriptionID)
            }
        }
        subscribers[documentID, default: [:]][subscriptionID] = pair.continuation
        pair.continuation.yield(status(documentID: documentID))
        return pair.stream
    }

    public func waitUntilSettled(documentID: UUID) async throws -> ExportStatus {
        try await waitUntilSettled(documentID: documentID, onWaiting: {})
    }

    func waitUntilSettled(documentID: UUID, onWaiting: @Sendable () -> Void) async throws -> ExportStatus {
        try Task.checkCancellation()
        guard case .saving = status(documentID: documentID) else { return status(documentID: documentID) }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExportStatus, Error>) in
                // Registration executes without suspension on this actor. Cancellation removal,
                // even if already queued, runs after registration; an already-canceled task exits here.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if case .saving = status(documentID: documentID) {
                    settlementWaiters[documentID, default: [:]][waiterID] = continuation
                    onWaiting()
                } else {
                    continuation.resume(returning: status(documentID: documentID))
                }
            }
        } onCancel: { [weak self] in
            Task { [weak self] in
                await self?.cancelWaiter(documentID: documentID, waiterID: waiterID)
            }
        }
    }

    /// Waits for this exact worker, including stale result disposal, without changing public status.
    func waitForEncodingCompletion(request: UInt64, onWaiting: () -> Void = {}) async {
        guard workers[request] != nil else { return }
        await withCheckedContinuation { continuation in
            workerWaiters[request, default: []].append(continuation)
            onWaiting()
        }
    }

    private func completed(_ request: ExportRequest, id: UInt64, result: Result<Data, Error>) {
        defer {
            workers.removeValue(forKey: id)
            let waiting = workerWaiters.removeValue(forKey: id) ?? []
            for continuation in waiting { continuation.resume() }
        }
        guard latest[request.documentID] == id else { return }
        do {
            let data = try result.get()
            // No await from the latest-request check through publication and its status update.
            let published = try writer.publish(documentID: request.documentID, createdAt: request.createdAt,
                                               slot: request.slot, destinationFolder: request.destinationFolder,
                                               data: data, stamp: ExportStamp(request: id, documentRevision: request.revision))
            transition(.saved(request: id, revision: request.revision, url: published.url),
                       documentID: request.documentID)
        } catch {
            transition(.failed(request: id, revision: request.revision, message: String(describing: error)),
                       documentID: request.documentID)
        }
    }

    private func transition(_ value: ExportStatus, documentID: UUID) {
        statuses[documentID] = value
        if let group = subscribers[documentID] {
            for continuation in group.values { continuation.yield(value) }
        }
        if case .saving = value { return }
        let waiting = settlementWaiters.removeValue(forKey: documentID) ?? [:]
        for continuation in waiting.values { continuation.resume(returning: value) }
    }

    private func cancelWaiter(documentID: UUID, waiterID: UUID) {
        let continuation = settlementWaiters[documentID]?.removeValue(forKey: waiterID)
        if settlementWaiters[documentID]?.isEmpty == true { settlementWaiters.removeValue(forKey: documentID) }
        continuation?.resume(throwing: CancellationError())
    }

    private func removeSubscriber(documentID: UUID, subscriptionID: UUID) {
        subscribers[documentID]?.removeValue(forKey: subscriptionID)
        if subscribers[documentID]?.isEmpty == true { subscribers.removeValue(forKey: documentID) }
    }
}
