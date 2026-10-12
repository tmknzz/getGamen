import CoreGraphics
import Foundation
import Observation
import GetGamenCore

enum EditorIssue {
    case rendering(Error)
    case persistence(Error)
    case exportPreparation(Error)
}

/// One document's continuing draft, preview and ordered persistence/export boundary.
@MainActor
@Observable
final class EditorSession {
    let documentID: UUID
    private(set) var persisted: EditDocument
    private(set) var draft: EditState
    private(set) var format: ExportFormat
    private(set) var preview: CGImage?
    private(set) var previewEdits: EditState?
    private(set) var issue: EditorIssue?
    private(set) var isProcessing = false
    private(set) var hasUnpersistedChanges = false
    private(set) var exportStatus: ExportStatus = .idle
    private(set) var isTerminationPending = false

    private var undoStates: [EditState] = []
    private var redoStates: [EditState] = []
    private var captureExportSettings: ExportSettingsSnapshot?
    private var retriesExplicitExport = false
    private var committedDraft: EditState
    var canUndo: Bool { !isTerminationPending && (!undoStates.isEmpty || draft != committedDraft) }
    var canRedo: Bool { !isTerminationPending && !redoStates.isEmpty && draft == committedDraft }

    func undoEdit() {
        guard canUndo else { return }
        if draft != committedDraft {
            setDraft(committedDraft)
            return
        }
        guard let state = undoStates.popLast() else { return }
        redoStates.append(committedDraft)
        restoreHistory(state)
    }

    func redoEdit() {
        guard canRedo, let state = redoStates.popLast() else { return }
        undoStates.append(committedDraft)
        restoreHistory(state)
    }

    private func restoreHistory(_ state: EditState) {
        committedDraft = state
        setDraft(state)
        enqueue(.edit(state, currentSettings()))
    }

    private let originalData: Data
    private let store: DocumentStore
    private let exports: AutomaticExportCoordinator
    private let settings: ExportSettings
    private let beforeSave: @MainActor () async throws -> Void
    private let beforeExportSubmit: @MainActor (ExportRequest) async throws -> Void
    @ObservationIgnored private var queue: [Operation] = []
    @ObservationIgnored private var blocked = false
    @ObservationIgnored private var worker: EditorWorker?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    private enum Operation {
        case edit(EditState, ExportSettingsSnapshot)
        case export(ExportSettingsSnapshot)
        case capture(ExportSettingsSnapshot)
    }

    static func open(
        documentID: UUID, store: DocumentStore, exports: AutomaticExportCoordinator,
        settings: ExportSettings, initialSettings: ExportSettingsSnapshot? = nil,
        initialPreview: CGImage? = nil,
        beforeSave: @escaping @MainActor () async throws -> Void = {},
        beforeExportSubmit: @escaping @MainActor (ExportRequest) async throws -> Void = { _ in }
    ) async throws -> EditorSession {
        let stored = try await store.load(id: documentID)
        let session = EditorSession(stored: stored, store: store, exports: exports,
                                    settings: settings, initialSettings: initialSettings,
                                    beforeSave: beforeSave, beforeExportSubmit: beforeExportSubmit)
        do {
            if let initialPreview, session.persisted.edits == EditState(),
               initialPreview.width == session.persisted.pixelSize.width,
               initialPreview.height == session.persisted.pixelSize.height {
                session.preview = initialPreview
            } else {
                session.preview = try session.render(session.persisted.edits)
            }
            session.previewEdits = session.persisted.edits
        } catch {
            session.issue = .rendering(error)
        }
        session.observeExports()
        return session
    }

    private init(
        stored: StoredDocument, store: DocumentStore, exports: AutomaticExportCoordinator,
        settings: ExportSettings, initialSettings: ExportSettingsSnapshot?,
        beforeSave: @escaping @MainActor () async throws -> Void,
        beforeExportSubmit: @escaping @MainActor (ExportRequest) async throws -> Void
    ) {
        documentID = stored.document.documentID
        persisted = stored.document
        draft = stored.document.edits
        committedDraft = stored.document.edits
        originalData = stored.originalData
        format = (initialSettings ?? settings.snapshot).format
        self.store = store
        self.exports = exports
        self.settings = settings
        self.beforeSave = beforeSave
        self.beforeExportSubmit = beforeExportSubmit
    }

    func setDraft(_ edits: EditState) {
        guard !isTerminationPending else { return }
        draft = edits
        updateDirtyStatus()
    }

    /// Call once per completed editing operation, including an explicit equal-state operation.
    func commitDraft() {
        guard !isTerminationPending else { return }
        if draft != committedDraft {
            undoStates.append(committedDraft)
            redoStates.removeAll()
            committedDraft = draft
        }
        enqueue(.edit(draft, currentSettings()))
    }

    func commitFormat(_ format: ExportFormat) {
        guard !isTerminationPending else { return }
        self.format = format
        settings.setFormat(format)
    }

    func commitJPEGQuality(_ quality: Double) throws {
        guard !isTerminationPending else { return }
        try settings.setJPEGQuality(quality)
    }

    /// Keep the first capture export independent of later edits and output preferences.
    func requestCaptureExport(using snapshot: ExportSettingsSnapshot) {
        guard !isTerminationPending else { return }
        retriesExplicitExport = false
        captureExportSettings = snapshot
        enqueue(.capture(snapshot))
    }

    func retryExport() {
        if retriesExplicitExport { requestExport(); return }
        let saved = captureExportSettings ?? currentSettings()
        let retry = ExportSettingsSnapshot(format: saved.format, jpegQuality: saved.jpegQuality,
                                           destination: settings.snapshot.destination)
        requestCaptureExport(using: retry)
    }

    func requestExport(using snapshot: ExportSettingsSnapshot? = nil) {
        guard !isTerminationPending else { return }
        retriesExplicitExport = true
        enqueue(.export(snapshot ?? currentSettings()))
    }

    func retryPending() {
        guard !isTerminationPending else { return }
        guard !queue.isEmpty, worker == nil, blocked else { return }
        blocked = false
        issue = nil
        startWorkerIfNeeded()
    }

    /// Observes only the worker at entry. It does not wait for asynchronous export settlement.
    /// Cancellation of this waiter never claims an outstanding save has finished.
    func waitUntilIdle() async {
        guard let observed = worker else { return }
        await observed.waitUntilFinished()
    }

    func beginTermination() { isTerminationPending = true }
    func endTermination() { isTerminationPending = false }

    private func currentSettings() -> ExportSettingsSnapshot {
        let shared = settings.snapshot
        return ExportSettingsSnapshot(format: format, jpegQuality: shared.jpegQuality,
                                      destination: shared.destination)
    }

    private func enqueue(_ operation: Operation) {
        queue.append(operation)
        updateDirtyStatus()
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !blocked, !queue.isEmpty else { return }
        let running = EditorWorker()
        worker = running
        isProcessing = true
        // A running save owns the session until it actually returns. finish breaks this cycle.
        running.task = Task { @MainActor in
            await self.drain()
            self.worker = nil
            self.isProcessing = false
            self.updateDirtyStatus()
            running.finish()
        }
    }

    private func drain() async {
        while let operation = queue.first {
            let edits: EditState
            let snapshot: ExportSettingsSnapshot
            let savesDocument: Bool
            switch operation {
            case .edit(let capturedEdits, let capturedSettings):
                edits = capturedEdits
                snapshot = capturedSettings
                savesDocument = true
            case .capture(let capturedSettings):
                edits = EditState()
                snapshot = capturedSettings
                savesDocument = false
            case .export(let capturedSettings):
                edits = persisted.edits
                snapshot = capturedSettings
                savesDocument = false
            }

            let rendered: CGImage
            do { rendered = try render(edits) }
            catch {
                issue = .rendering(error)
                blocked = true
                return
            }
            if savesDocument {
                do {
                    try await beforeSave()
                    persisted = try await store.save(id: documentID, edits: edits,
                                                     expectedRevision: persisted.revision)
                } catch {
                    issue = .persistence(error)
                    blocked = true
                    return
                }
            }
            // This preview represents persisted pixels, never a newer unpersisted draft.
            if case .capture = operation {} else {
                preview = rendered
                previewEdits = persisted.edits
            }
            updateDirtyStatus()
            do {
                if !savesDocument {
                    try await submitExport(snapshot, edits: edits, revision: {
                        if case .capture = operation { return 0 }
                        return persisted.revision
                    }())
                    issue = nil
                } else if case .exportPreparation = issue {
                    // An edit cannot resolve a failed capture export.
                } else {
                    issue = nil
                }
            } catch {
                // Saving already succeeded (or this was an equal-revision export).
                // Retain that document and remove only this attempted export operation.
                issue = .exportPreparation(error)
            }
            queue.removeFirst()
            updateDirtyStatus()
        }
    }

    func renderDraft(_ edits: EditState) throws -> CGImage { try render(edits) }

    private func render(_ edits: EditState) throws -> CGImage {
        try EditRenderer.render(originalData: originalData, pixelSize: persisted.pixelSize, edits: edits)
    }

    private func submitExport(_ snapshot: ExportSettingsSnapshot, edits: EditState, revision: UInt64) async throws {
        let destination = try ExportSettings.prepareDestination(for: snapshot)
        let codecFormat = try snapshot.format.codecFormat(jpegQuality: snapshot.jpegQuality)
        let data = originalData
        let size = persisted.pixelSize
        let request = ExportRequest(documentID: documentID, revision: revision,
                                    slot: snapshot.format.slot, createdAt: persisted.createdAt,
                                    destinationFolder: destination, encode: {
            let flattened = try EditRenderer.render(originalData: data, pixelSize: size, edits: edits)
            return try RasterImageCodec.encode(flattened, format: codecFormat)
        })
        try await beforeExportSubmit(request)
        try await exports.submit(request)
    }

    private func updateDirtyStatus() {
        hasUnpersistedChanges = draft != persisted.edits || queue.contains { operation in
            if case .edit = operation { return true }
            return false
        }
    }

    private func observeExports() {
        let exports = exports
        let id = documentID
        statusTask = Task { @MainActor [weak self] in
            let updates = await exports.updates(documentID: id)
            for await status in updates {
                guard !Task.isCancelled else { break }
                // Never promote weak self across the stream's next suspension.
                self?.exportStatus = status
            }
        }
    }

    deinit { statusTask?.cancel() }
}

@MainActor
private final class EditorWorker {
    var task: Task<Void, Never>?
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        task = nil
        let completed = waiters
        waiters.removeAll()
        for waiter in completed { waiter.resume() }
    }
}
