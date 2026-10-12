import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import GetGamen
@testable import GetGamenCore

/// Actual app-owned window construction/lifecycle, not physical input or screenshot evidence.
final class EditorWindowTests: XCTestCase {
    @MainActor
    func testRepeatedEditorCloseReleasesSessionAndInteraction() async throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = f.coordinator()
        for iteration in 0..<20 {
            let document = try await f.create(size: 1024)
            weak var releasedSession: EditorSession?
            weak var releasedInteraction: EditorInteraction?
            var session: EditorSession? = try await owner.openEditor(documentID: document.documentID)
            releasedSession = session
            autoreleasepool {
                let window = owner.window(for: document.documentID)
                releasedInteraction = owner.interaction(for: document.documentID)
                XCTAssertNotNil(releasedInteraction)
                window?.performClose(nil)
            }
            session = nil
            await owner.closeDeletion?.value
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(owner.window(for: document.documentID))
            XCTAssertNil(releasedSession, "Session retained at iteration \(iteration)")
            XCTAssertNil(releasedInteraction, "Interaction retained at iteration \(iteration)")
        }
    }

    func testWindowSizeFollowsImageAndCapsAtUsableDisplay() {
        let visible = NSRect(x: -1600, y: 30, width: 1600, height: 1000)
        let minimum = NSSize(width: 560, height: 400)
        let chrome = NSSize(width: 20, height: 200)
        let medium = EditorWindowSizing.frame(imagePixels: NSSize(width: 2000, height: 1200), scale: 2,
            chrome: chrome, minimum: minimum, visible: visible)
        XCTAssertEqual(medium.size, NSSize(width: 1020, height: 800))
        XCTAssertTrue(visible.contains(medium))
        let large = EditorWindowSizing.frame(imagePixels: NSSize(width: 5000, height: 4000), scale: 2,
            chrome: chrome, minimum: minimum, visible: visible)
        XCTAssertEqual(large, visible)
        let small = EditorWindowSizing.frame(imagePixels: NSSize(width: 100, height: 100), scale: 1,
            chrome: chrome, minimum: minimum, visible: visible)
        XCTAssertEqual(small.size, minimum)
    }

    @MainActor
    func testConcurrentOpenLoadsOnceReusesWindowAndPreservesSession() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let gate = Gate(); defer { gate.finish(.failure(Injected.failed)) }
        var loads = 0
        let owner = f.coordinator { loads += 1; try await gate.run() }
        let initial = ExportSettingsSnapshot(format: .png8, jpegQuality: 0.9, destination: .configuredFolder(f.output))
        let a = Task { try await owner.openEditor(documentID: document.documentID, initialSettings: initial) }
        defer { a.cancel() }
        try await gate.waitStarted()
        let entered = XCTestExpectation(description: "Second caller entered")
        let b = Task { entered.fulfill(); return try await owner.openEditor(documentID: document.documentID) }
        defer { b.cancel() }
        try await ack(entered)
        XCTAssertEqual(loads, 1)
        XCTAssertNil(owner.window(for: document.documentID))
        gate.finish(.success(()))
        let first = try await result(a).get(); let second = try await result(b).get()
        XCTAssertTrue(first === second)
        let window = try XCTUnwrap(owner.window(for: document.documentID))
        XCTAssertTrue(window.isVisible)
        if let screen = window.screen, screen.visibleFrame.width > 560 {
            XCTAssertEqual(window.frame.width, 560, accuracy: 1, "Small images should not maximize the editor")
        }
        XCTAssertEqual(window.identifier?.rawValue, document.documentID.uuidString)
        let host = try XCTUnwrap(window.contentViewController as? NSHostingController<EditorView>)
        XCTAssertTrue(host.rootView.session === first)
        let draft = EditState(objects: [EditObject(id: UUID(), bounds: PixelBounds(x: -1, y: 0, width: 1, height: 1), style: .grayMask(brightness: 0.5))])
        first.setDraft(draft)
        let reused = try await owner.openEditor(documentID: document.documentID,
            initialSettings: ExportSettingsSnapshot(format: .jpeg, jpegQuality: 0.1, destination: .configuredFolder(f.output)))
        XCTAssertTrue(reused === first); XCTAssertEqual(reused.draft, draft)
        XCTAssertEqual(reused.format, .png8); XCTAssertEqual(loads, 1)
        XCTAssertTrue(owner.window(for: document.documentID) === window)
        let status = await f.exports.status(documentID: document.documentID)
        XCTAssertEqual(status, .idle)
    }

    @MainActor
    func testOneCancelledCallerDoesNotCancelOtherSharedLoadOrCreateExtraWindow() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let gate = Gate(); defer { gate.finish(.failure(Injected.failed)) }
        var loads = 0
        let owner = f.coordinator { loads += 1; try await gate.run() }
        let cancelled = Task { try await owner.openEditor(documentID: document.documentID) }
        defer { cancelled.cancel() }
        try await gate.waitStarted()
        let entered = XCTestExpectation(description: "Live caller joined")
        let live = Task { entered.fulfill(); return try await owner.openEditor(documentID: document.documentID) }
        defer { live.cancel() }
        try await ack(entered)
        cancelled.cancel()
        XCTAssertNil(owner.window(for: document.documentID))
        gate.finish(.success(()))
        let rejected = try await result(cancelled)
        assertCancellation(rejected)
        let session = try await result(live).get()
        XCTAssertEqual(session.documentID, document.documentID)
        XCTAssertNotNil(owner.window(for: document.documentID))
        XCTAssertEqual(loads, 1)
    }

    @MainActor
    func testAllCancelledCallersNeverPresentAndRetryCreatesFreshWindow() async throws {
        for loadFails in [false, true] {
            let f = try Fixture(); defer { f.remove() }
            let document = try await f.create()
            let gate = Gate(); defer { gate.finish(.failure(Injected.failed)) }
            var loads = 0
            let owner = f.coordinator {
                loads += 1
                if loads == 1 { try await gate.run() }
            }
            let a = Task { try await owner.openEditor(documentID: document.documentID) }
            defer { a.cancel() }
            try await gate.waitStarted()
            let entered = XCTestExpectation(description: "Second cancelled caller joined")
            let b = Task { entered.fulfill(); return try await owner.openEditor(documentID: document.documentID) }
            defer { b.cancel() }
            try await ack(entered)
            a.cancel(); b.cancel()
            XCTAssertNil(owner.window(for: document.documentID))
            gate.finish(loadFails ? .failure(Injected.failed) : .success(()))
            assertCancellation(try await result(a)); assertCancellation(try await result(b))
            XCTAssertNil(owner.window(for: document.documentID))
            let retried = try await result(Task { try await owner.openEditor(documentID: document.documentID) }).get()
            XCTAssertEqual(retried.documentID, document.documentID)
            XCTAssertEqual(loads, 2)
            XCTAssertTrue(try XCTUnwrap(owner.window(for: document.documentID)).isVisible)
        }
    }

    @MainActor
    func testLoadFailureClearsPendingAndExistingCancelledOpenDoesNotFocus() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        var fails = true
        let owner = f.coordinator { if fails { throw Injected.failed } }
        let failure = try await result(Task { try await owner.openEditor(documentID: document.documentID) })
        do { _ = try failure.get(); XCTFail("Load checkpoint failure ignored") }
        catch { XCTAssertEqual(error as? Injected, .failed) }
        XCTAssertNil(owner.window(for: document.documentID))
        fails = false
        let session = try await owner.openEditor(documentID: document.documentID)
        let window = try XCTUnwrap(owner.window(for: document.documentID))
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await owner.openEditor(documentID: document.documentID)
        }
        assertCancellation(try await result(cancelled))
        XCTAssertFalse(window.isVisible, "Cancelled existing-entry call must not refocus")
        XCTAssertTrue(owner.window(for: document.documentID) === window)
        XCTAssertEqual(session.documentID, document.documentID)
    }

    @MainActor
    func testImmediateRetryAfterSharedFailureDoesNotReuseFailedTaskOrLoseReplacement() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let gate = Gate(); defer { gate.finish(.failure(Injected.failed)) }
        var loads = 0
        let owner = f.coordinator {
            loads += 1
            if loads == 1 { try await gate.run() }
        }
        let openAndRetry: @MainActor () async throws -> EditorSession = {
            do { return try await owner.openEditor(documentID: document.documentID) }
            catch {
                XCTAssertEqual(error as? Injected, .failed)
                // Re-enter immediately on this actor, while other failed callers may still unwind.
                return try await owner.openEditor(documentID: document.documentID)
            }
        }
        let a = Task { try await openAndRetry() }; defer { a.cancel() }
        try await gate.waitStarted()
        let entered = XCTestExpectation(description: "Second shared failure caller joined")
        let b = Task { entered.fulfill(); return try await openAndRetry() }; defer { b.cancel() }
        try await ack(entered)
        gate.finish(.failure(Injected.failed))
        let first = try await result(a).get(); let second = try await result(b).get()
        XCTAssertTrue(first === second)
        XCTAssertEqual(loads, 2)
        XCTAssertNotNil(owner.window(for: document.documentID))
    }

    @MainActor
    func testPerformCloseRefusesProcessingAndBlockedDraftThenSafeCloseDeletesOnlyThatDocument() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let other = try await f.create()
        let owner = f.coordinator()
        let session = try await owner.openEditor(documentID: document.documentID)
        let window = try XCTUnwrap(owner.window(for: document.documentID))
        let otherSession = try await owner.openEditor(documentID: other.documentID)
        let otherWindow = try XCTUnwrap(owner.window(for: other.documentID))
        session.commitDraft()
        XCTAssertTrue(session.isProcessing)
        window.performClose(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(owner.window(for: document.documentID) === window)
        let idle: Task<Void, Error> = Task { await session.waitUntilIdle() }
        _ = try await result(idle).get()
        let settled = try await result(Task { try await f.exports.waitUntilSettled(documentID: document.documentID) }).get()
        XCTAssertEqual(settled, .idle, "Editing persists history without publishing an image")
        XCTAssertFalse(session.hasUnpersistedChanges)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible); XCTAssertNil(owner.window(for: document.documentID))
        await owner.closeDeletion?.value
        let stored = try await f.store.documentIDs()
        XCTAssertEqual(stored, [other.documentID])
        otherSession.setDraft(EditState(objects: [EditObject(id: UUID(), bounds: PixelBounds(x: -1, y: 0, width: 1, height: 1), style: .grayMask(brightness: 0.5))]))
        otherSession.commitDraft()
        let blocked: Task<Void, Error> = Task { await otherSession.waitUntilIdle() }
        _ = try await result(blocked).get()
        XCTAssertTrue(otherSession.hasUnpersistedChanges)
        if case .rendering? = otherSession.issue {} else { XCTFail("Expected real invalid-edit failure") }
        otherWindow.performClose(nil)
        XCTAssertTrue(otherWindow.isVisible)
        XCTAssertTrue(owner.window(for: other.documentID) === otherWindow)
        // A direct close bypasses the close policy but must not discard unsaved work.
        let lastDeletion = owner.closeDeletion
        otherWindow.close()
        XCTAssertNil(owner.window(for: other.documentID))
        XCTAssertEqual(owner.closeDeletion, lastDeletion, "Unsaved work starts no deletion")
        let kept = try await f.store.documentIDs()
        XCTAssertEqual(kept, [other.documentID])
    }

    @MainActor
    func testRuntimeForwardsActualCoordinatorWithoutChangingCaptureActivity() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let windows = f.coordinator()
        let runtime = AppRuntime(captureSettings: CaptureSettings(defaults: f.defaults), exportSettings: f.settings,
            editorWindows: windows, cancelShortcut: HotKeyShortcut(keyCode: 53, modifiers: 0),
            prepare: { _, _, _ in XCTFail("Editor open initiated capture"); throw Injected.failed },
            wait: { _, _ in XCTFail("Editor open started timer") },
            didCapture: { _, _ in XCTFail("Editor open handed off capture") })
        let initial = ExportSettingsSnapshot(format: .png8, jpegQuality: 0.3, destination: .configuredFolder(f.output))
        let session = try await runtime.openEditor(documentID: document.documentID, initialSettings: initial)
        XCTAssertTrue(try XCTUnwrap(windows.window(for: document.documentID)).isVisible)
        XCTAssertEqual(session.format, .png8)
        XCTAssertEqual(runtime.activity, .idle)
        XCTAssertNil(runtime.failureMessage); XCTAssertNil(runtime.previousRecordWarning)
        let status = await f.exports.status(documentID: document.documentID)
        XCTAssertEqual(status, .idle)
    }

    private enum Injected: Error, Equatable { case failed, timeout }
    @MainActor private func assertCancellation<Value>(_ result: Result<Value, Error>) {
        do { _ = try result.get(); XCTFail("Cancelled caller succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor private func ack(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw Injected.timeout }
    }
    @MainActor private func result<Value>(_ task: Task<Value, Error>) async throws -> Result<Value, Error> {
        let finished = XCTestExpectation(description: "Editor window operation completed")
        let observer = Task { let value = await task.result; finished.fulfill(); return value }
        do { try await ack(finished) }
        catch { task.cancel(); observer.cancel(); throw error }
        return await observer.value
    }
    @MainActor private final class Gate {
        let entered = XCTestExpectation(description: "Shared actual load checkpoint entered")
        private var started = false
        private var continuation: CheckedContinuation<Void, Error>?
        private var early: Result<Void, Error>?
        func run() async throws {
            precondition(!started); started = true; entered.fulfill()
            if let early { return try early.get() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func waitStarted() async throws {
            if started { return }
            let result = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            XCTAssertEqual(result, .completed)
            guard result == .completed else { finish(.failure(Injected.failed)); throw Injected.timeout }
        }
        func finish(_ value: Result<Void, Error>) { early = value; let pending = continuation; continuation = nil; pending?.resume(with: value) }
    }
    @MainActor private final class Fixture {
        let suite = "getGamen.EditorWindowTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        let output: URL
        let store: DocumentStore
        let exports: AutomaticExportCoordinator
        let settings: ExportSettings
        var owners: [EditorWindowCoordinator] = []
        var ids: [UUID] = []
        init() throws {
            _ = NSApplication.shared
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-window-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            output = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            store = try DocumentStore(root: root.appendingPathComponent("documents", isDirectory: true))
            exports = try AutomaticExportCoordinator(receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true))
            settings = ExportSettings(defaults: defaults, defaultFolder: root.appendingPathComponent("getGamen", isDirectory: true))
            try settings.setDestinationFolder(output)
        }
        func create(size: Int = 1) async throws -> EditDocument {
            let pixels = [UInt8](repeating: 128, count: size * size * 4)
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
            let image = try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let data = try RasterImageCodec.encode(image, format: .png)
            let document = try await store.create(original: data, pixelSize: PixelSize(width: size, height: size))
            ids.append(document.documentID)
            return document
        }
        func coordinator(beforeLoad: @escaping @MainActor () async throws -> Void = {}) -> EditorWindowCoordinator {
            let owner = EditorWindowCoordinator(store: store, exports: exports, settings: settings, beforeLoad: beforeLoad)
            owners.append(owner); return owner
        }
        func remove() {
            // Direct close is teardown only; ordinary close-policy assertions above use performClose.
            for owner in owners { for id in ids { owner.window(for: id)?.close() } }
            owners.removeAll()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
