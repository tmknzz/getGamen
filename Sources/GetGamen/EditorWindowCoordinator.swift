import AppKit
import SwiftUI
import GetGamenCore

enum EditorWindowError: Error, Equatable { case terminationInProgress, deletionInProgress, unsavedChanges }

enum EditorWindowSizing {
    static func frame(imagePixels: NSSize, scale: CGFloat, chrome: NSSize,
                      minimum: NSSize, visible: NSRect) -> NSRect {
        let width = min(visible.width, max(minimum.width, ceil(imagePixels.width / scale) + chrome.width))
        let height = min(visible.height, max(minimum.height, ceil(imagePixels.height / scale) + chrome.height))
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }
}

/// One live window/session per document. Shared asynchronous work loads data only.
@MainActor
final class EditorWindowCoordinator {
    var willPresentEditor: (() -> Void)?
    private let store: DocumentStore
    private let exports: AutomaticExportCoordinator
    private let settings: ExportSettings
    private let beforeLoad: @MainActor () async throws -> Void
    private var entries: [UUID: EditorWindowController] = [:]
    private var deleting = Set<UUID>()
    /// The latest close-triggered deletion; tests await it.
    private(set) var closeDeletion: Task<Void, Never>?
    private var pending: [UUID: PendingOpen] = [:]
    private(set) var isTerminationPending = false
    private var terminationSessions: [EditorSession] = []
    private var terminationLoads: [Task<EditorSession, Error>] = []

    init(store: DocumentStore, exports: AutomaticExportCoordinator, settings: ExportSettings,
         beforeLoad: @escaping @MainActor () async throws -> Void = {}) {
        self.store = store; self.exports = exports; self.settings = settings; self.beforeLoad = beforeLoad
    }

    var active: (EditorInteraction, EditorViewport)? {
        guard let entry = entries.values.first(where: { $0.window === NSApp.keyWindow }) else { return nil }
        return (entry.interaction, entry.viewport)
    }

    func window(for documentID: UUID) -> NSWindow? { entries[documentID]?.window }

    func openEditor(documentID: UUID, initialSettings: ExportSettingsSnapshot? = nil,
                    initialPreview: CGImage? = nil) async throws -> EditorSession {
        guard !isTerminationPending else { throw EditorWindowError.terminationInProgress }
        try Task.checkCancellation()
        guard !deleting.contains(documentID) else { throw EditorWindowError.deletionInProgress }
        if let existing = entries[documentID] {
            existing.present()
            return existing.session
        }
        let loading: PendingOpen
        if let existing = pending[documentID] { loading = existing }
        else {
            let store = store, exports = exports, settings = settings, beforeLoad = beforeLoad
            loading = PendingOpen(task: Task { @MainActor in
                try await beforeLoad()
                return try await EditorSession.open(documentID: documentID, store: store, exports: exports,
                                                    settings: settings, initialSettings: initialSettings,
                                                    initialPreview: initialPreview)
            })
            pending[documentID] = loading
        }
        loading.waiterCount += 1
        defer {
            loading.waiterCount -= 1
            if loading.waiterCount == 0, pending[documentID] === loading { pending.removeValue(forKey: documentID) }
        }
        let session: EditorSession
        do { session = try await loading.task.value }
        catch {
            if pending[documentID] === loading { pending.removeValue(forKey: documentID) }
            try Task.checkCancellation()
            throw error
        }
        // No await between the caller's cancellation check and native creation/focus.
        try Task.checkCancellation()
        guard !isTerminationPending else { throw EditorWindowError.terminationInProgress }
        guard !deleting.contains(documentID), !loading.invalidated else { throw EditorWindowError.deletionInProgress }
        if let existing = entries[documentID] {
            existing.present()
            return existing.session
        }
        let controller = EditorWindowController(session: session, settings: settings, owner: self)
        entries[documentID] = controller
        controller.present()
        return session
    }

    func deleteDocument(_ id: UUID, onReserved: () -> Void = {}) async throws {
        guard !isTerminationPending, deleting.insert(id).inserted else { throw EditorWindowError.deletionInProgress }
        defer { deleting.remove(id) }
        pending[id]?.invalidated = true
        onReserved()
        let controller = entries[id]
        controller?.session.beginTermination()
        defer { if !isTerminationPending { controller?.session.endTermination() } }
        if let load = pending[id] { _ = try await load.task.value }
        if let session = controller?.session {
            await session.waitUntilIdle()
            guard !session.hasUnpersistedChanges else { throw EditorWindowError.unsavedChanges }
        }
        try await store.delete(id: id)
        entries.removeValue(forKey: id) // before close(), or closed() would delete again
        controller?.close()
    }

    func beginTermination() {
        guard !isTerminationPending else { return }
        isTerminationPending = true
        terminationSessions = entries.values.map(\.session)
        terminationLoads = pending.values.map(\.task)
        terminationSessions.forEach { $0.beginTermination() }
    }

    func waitForTerminationReadiness() async -> [EditorSession] {
        guard isTerminationPending else { return [] }
        for task in terminationLoads {
            if let session = try? await task.value {
                session.beginTermination()
                if !terminationSessions.contains(where: { $0 === session }) { terminationSessions.append(session) }
            }
        }
        terminationLoads.removeAll()
        for session in terminationSessions { await session.waitUntilIdle() }
        return terminationSessions
    }

    func endTermination() {
        terminationSessions.forEach { $0.endTermination() }
        terminationSessions.removeAll()
        terminationLoads.removeAll()
        isTerminationPending = false
    }

    func presentDirtyEditors() {
        for entry in entries.values where entry.session.hasUnpersistedChanges { entry.present() }
    }

    /// A closed document cannot be reopened, so its stored copy goes with the window.
    /// A direct close of busy or unsaved work keeps it; the next launch discards it.
    fileprivate func closed(documentID: UUID, controller: EditorWindowController) {
        guard entries[documentID] === controller else { return }
        entries.removeValue(forKey: documentID)
        // deleteDocument no longer sees this entry, so this guard is the unsaved-work check.
        guard !isTerminationPending, controller.canDiscard else { return }
        closeDeletion = Task { [weak self] in
            do { try await self?.deleteDocument(documentID) }
            catch { NSLog("getGamen kept a closed document until the next launch: %@", String(describing: error)) }
        }
    }

    func interaction(for documentID: UUID) -> EditorInteraction? { entries[documentID]?.interaction }

    private final class PendingOpen {
        let task: Task<EditorSession, Error>
        var waiterCount = 0
        var invalidated = false
        init(task: Task<EditorSession, Error>) { self.task = task }
    }
}

@MainActor
fileprivate final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let session: EditorSession
    let interaction: EditorInteraction
    let viewport = EditorViewport()
    private weak var windowCoordinator: EditorWindowCoordinator?

    init(session: EditorSession, settings: ExportSettings, owner: EditorWindowCoordinator) {
        self.session = session; self.windowCoordinator = owner
        interaction = EditorInteraction(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(session.documentID.uuidString)
        window.title = CaptureFilename.stem(createdAt: session.persisted.createdAt)
        let host = NSHostingController(rootView: EditorView(session: session, settings: settings, interaction: interaction, viewport: viewport))
        host.sizingOptions = []
        window.contentViewController = host
        window.contentMinSize = NSSize(width: 560, height: 380)
        window.setContentSize(NSSize(width: 900, height: 660))
        super.init(window: window)
        window.delegate = self
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
            host.view.layoutSubtreeIfNeeded()
            func canvas(in view: NSView) -> EditorCanvasScrollView? {
                if let canvas = view as? EditorCanvasScrollView { return canvas }
                return view.subviews.lazy.compactMap { canvas(in: $0) }.first
            }
            let available = canvas(in: host.view)?.contentView.bounds.size
            let chrome = available.map { NSSize(width: window.frame.width - $0.width,
                                                height: window.frame.height - $0.height) }
                ?? NSSize(width: 20, height: 240)
            let image = session.preview
            let imageSize = NSSize(width: image?.width ?? session.persisted.pixelSize.width,
                                   height: image?.height ?? session.persisted.pixelSize.height)
            let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
            window.setFrame(EditorWindowSizing.frame(imagePixels: imageSize, scale: screen.backingScaleFactor,
                chrome: chrome, minimum: minimum, visible: screen.visibleFrame), display: false)
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        windowCoordinator?.willPresentEditor?()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    var canDiscard: Bool { !session.isProcessing && !session.hasUnpersistedChanges }

    func windowShouldClose(_ sender: NSWindow) -> Bool { canDiscard }

    func windowWillClose(_ notification: Notification) {
        windowCoordinator?.closed(documentID: session.documentID, controller: self)
    }
}
