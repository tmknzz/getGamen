import AppKit
import Observation
import GetGamenCore

struct CaptureDeliveryOutcome: Equatable {
    enum Disposition: Equatable {
        /// Queued on the real session; output success is reported by its export status.
        case exportRequested
        case retainedAfterCancellation
        case retainedAfterFailure(message: String)
    }

    let operationID: UUID
    let documentID: UUID
    let disposition: Disposition
}

/// AppRuntime owns serial delivery and resets the outcome only when accepting a new capture.
@MainActor
@Observable
final class CapturedDocumentHandoff {
    let editorWindows: EditorWindowCoordinator
    private(set) var outcome: CaptureDeliveryOutcome?
    private let store: DocumentStore
    private let pasteboard: NSPasteboard
    private let beforeCreate: @MainActor () async throws -> Void
    private let afterOriginalStored: @MainActor (EditDocument) async throws -> Void

    init(store: DocumentStore, editorWindows: EditorWindowCoordinator, pasteboard: NSPasteboard = .general,
         beforeCreate: @escaping @MainActor () async throws -> Void = {},
         afterOriginalStored: @escaping @MainActor (EditDocument) async throws -> Void = { _ in }) {
        self.store = store
        self.editorWindows = editorWindows
        self.pasteboard = pasteboard
        self.beforeCreate = beforeCreate
        self.afterOriginalStored = afterOriginalStored
    }

    func resetOutcome() { outcome = nil }

    func accept(_ captured: CapturedImage, intent: CaptureIntent) async throws {
        var stored: EditDocument?
        do {
            try Task.checkCancellation()
            let image = captured.image
            let original = try await Task.detached {
                try RasterImageCodec.encode(image, format: .png)
            }.value
            if captured.copiesToClipboard && intent.allowsCopyOnly {
                // Cmd+C copies only, like macOS Control-capture: no document, editor or export.
                let rendered = try await Task.detached {
                    try EditRenderer.render(originalData: original,
                        pixelSize: PixelSize(width: image.width, height: image.height), edits: EditState())
                }.value
                try Task.checkCancellation()
                try EditorInteraction.writeImage(rendered, to: pasteboard)
                return
            }
            try await beforeCreate()
            try Task.checkCancellation()
            let document = try await store.create(original: original,
                pixelSize: PixelSize(width: image.width, height: image.height))
            // Cancellation cannot undo an already published immutable original.
            stored = document
            try await afterOriginalStored(document)
            try Task.checkCancellation()
            let session = try await editorWindows.openEditor(documentID: document.documentID,
                                                             initialSettings: intent.export, initialPreview: image)
            try Task.checkCancellation()
            if captured.copiesToClipboard { try EditorInteraction(session: session).copyImage(to: pasteboard) }
            session.requestCaptureExport(using: intent.export)
            outcome = CaptureDeliveryOutcome(operationID: intent.id, documentID: document.documentID,
                                              disposition: .exportRequested)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            if let stored {
                outcome = CaptureDeliveryOutcome(operationID: intent.id, documentID: stored.documentID,
                    disposition: cancelled ? .retainedAfterCancellation :
                        .retainedAfterFailure(message: error.localizedDescription))
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }
}
