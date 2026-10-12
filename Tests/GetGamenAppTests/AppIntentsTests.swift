import AppKit
import CoreGraphics
import Darwin
import ImageIO
import SwiftUI
import XCTest
@testable import GetGamen
@testable import GetGamenCore

final class AppIntentsTests: XCTestCase {
    func testCaptureResultReturnsMatchingDocument() {
        let operationID = UUID()
        let documentID = UUID()
        let outcome = CaptureDeliveryOutcome(operationID: operationID, documentID: documentID,
                                             disposition: .exportRequested)
        XCTAssertEqual(IntentHost.captureResult(operationID: operationID, outcome: outcome,
                                               failureMessage: "stale"), .success(documentID))
    }

    func testCaptureResultWithoutOutcome() {
        let operationID = UUID()
        XCTAssertEqual(IntentHost.captureResult(operationID: operationID, outcome: nil,
                                               failureMessage: nil), .failure(.cancelled))
        XCTAssertEqual(IntentHost.captureResult(operationID: operationID, outcome: nil,
                                               failureMessage: "x"), .failure(.failed("x")))
    }

    func testCaptureResultIgnoresDifferentOperation() {
        let outcome = CaptureDeliveryOutcome(operationID: UUID(), documentID: UUID(),
                                             disposition: .exportRequested)
        let operationID = UUID()
        XCTAssertEqual(IntentHost.captureResult(operationID: operationID, outcome: outcome,
                                               failureMessage: nil), .failure(.cancelled))
        XCTAssertEqual(IntentHost.captureResult(operationID: operationID, outcome: outcome,
                                               failureMessage: "x"), .failure(.failed("x")))
    }

    func testCaptureResultRetainedAfterCancellation() {
        let operationID = UUID()
        let outcome = CaptureDeliveryOutcome(operationID: operationID, documentID: UUID(),
                                             disposition: .retainedAfterCancellation)
        XCTAssertEqual(IntentHost.captureResult(operationID: operationID, outcome: outcome,
                                               failureMessage: "stale"), .failure(.cancelled))
    }

    func testCaptureResultRetainedAfterFailure() {
        let operationID = UUID()
        let outcome = CaptureDeliveryOutcome(operationID: operationID, documentID: UUID(),
                                             disposition: .retainedAfterFailure(message: "x"))
        XCTAssertEqual(IntentHost.captureResult(operationID: operationID, outcome: outcome,
                                               failureMessage: "stale"), .failure(.failed("x")))
    }

    func testShortcutsRunnerPath() {
        XCTAssertTrue(GetGamenApplicationDelegate.isShortcutsRunner(path:
            "/System/Library/PrivateFrameworks/WorkflowKit.framework/XPCServices/BackgroundShortcutRunner.xpc/Contents/MacOS/BackgroundShortcutRunner"))
        XCTAssertFalse(GetGamenApplicationDelegate.isShortcutsRunner(path: "/usr/bin/open"))
        XCTAssertFalse(GetGamenApplicationDelegate.isShortcutsRunner(path:
            "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))
        XCTAssertFalse(GetGamenApplicationDelegate.isShortcutsRunner(path: nil))
    }

    func testShortcutsEventWithoutSenderPID() {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass,
            eventID: kAEReopenApplication, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(GetGamenApplicationDelegate.isShortcutsEvent(event, launchIsDefault: nil))
        XCTAssertFalse(GetGamenApplicationDelegate.isShortcutsEvent(event, launchIsDefault: true))
        let open = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass,
            eventID: kAEOpenApplication, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(GetGamenApplicationDelegate.isShortcutsEvent(open, launchIsDefault: true))
    }

    // ローカルで作成した Apple event は keySenderPIDAttr を持てない（Apple Event Manager が受信イベントに設定する）ため、属性の読み取りは実機で検証する。
    func testExecutablePathForCurrentProcess() throws {
        XCTAssertFalse(try XCTUnwrap(GetGamenApplicationDelegate.executablePath(pid: getpid())).isEmpty)
        XCTAssertNil(GetGamenApplicationDelegate.executablePath(pid: 0))
    }

    func testShortcutsLaunchWithoutEvent() {
        XCTAssertTrue(GetGamenApplicationDelegate.isShortcutsEvent(nil, launchIsDefault: false))
        XCTAssertFalse(GetGamenApplicationDelegate.isShortcutsEvent(nil, launchIsDefault: true))
        XCTAssertFalse(GetGamenApplicationDelegate.isShortcutsEvent(nil, launchIsDefault: nil))
    }

    @MainActor
    func testCaptureFlowReturnsOriginalPNG() async throws {
        let f = try fixture()
        _ = f.configure { _, _, _ in f.prepared() }
        let data = try await value(f.capture())
        try assertPNG(data)
        XCTAssertEqual(f.storedIDs.count, 1)
        XCTAssertNotNil(f.windows.window(for: try XCTUnwrap(f.storedIDs.first)))
    }

    @MainActor
    func testCaptureFlowWithCopyConfirmationStillReturnsPNG() async throws {
        let f = try fixture()
        let chooser = f.configure { _, _, _ in f.prepared(copiesToClipboard: true) }
        let runtime = chooser.runtime
        let data = try await value(f.capture())
        try assertPNG(data)
        XCTAssertNotNil(f.pasteboard.data(forType: .png))
        let outcome = try XCTUnwrap(runtime.deliveryOutcome)
        XCTAssertEqual(outcome.disposition, .exportRequested)
        XCTAssertEqual(f.storedIDs, [outcome.documentID])
    }

    @MainActor
    func testCaptureFlowTranslatesLoadFailure() async throws {
        let f = try fixture()
        let chooser = f.configure { _, _, _ in f.prepared() }
        let runtime = chooser.runtime
        do {
            _ = try await value(f.capture(load: { _ in throw Injected.boom }))
            XCTFail("読み込みエラーが返るはず")
        } catch {
            XCTAssertEqual(error as? CaptureIntentError, .failed("boom"))
        }
        let outcome = try XCTUnwrap(runtime.deliveryOutcome)
        XCTAssertEqual(outcome.disposition, .exportRequested)
        XCTAssertEqual(f.storedIDs, [outcome.documentID])
    }

    @MainActor
    func testCaptureFlowCancelledDuringSelection() async throws {
        let f = try fixture()
        let gate = f.gate()
        let chooser = f.configure { _, _, _ in
            try await gate.run()
            return f.prepared()
        }
        let runtime = chooser.runtime
        let task = f.capture()
        try await ack(gate.entered)
        XCTAssertEqual(runtime.activity, .selecting)
        chooser.cancel()
        gate.finish(.failure(CancellationError()))
        do {
            _ = try await value(task)
            XCTFail("Expected cancelled capture")
        } catch {
            XCTAssertEqual(error as? CaptureIntentError, .cancelled)
        }
        XCTAssertTrue(f.storedIDs.isEmpty)
    }

    @MainActor
    func testCaptureFlowOuterCancellationWithdrawsSelectingCapture() async throws {
        let f = try fixture()
        let gate = f.gate()
        let chooser = f.configure { _, _, _ in
            try await gate.run()
            return f.prepared()
        }
        let runtime = chooser.runtime
        let task = f.capture()
        try await ack(gate.entered)
        XCTAssertEqual(runtime.activity, .selecting)
        let withdrawn = XCTestExpectation(description: "Outer cancellation withdraws the selecting capture")
        f.onActivity { if $0 == .cancelling { withdrawn.fulfill() } }
        task.cancel()
        try await ack(withdrawn)
        gate.finish(.failure(CancellationError()))
        do {
            _ = try await value(task)
            XCTFail("Expected cancelled capture")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? CaptureIntentError) == .cancelled,
                          "Unexpected error: \(error)")
        }
        await runtime.waitUntilIdle()
        XCTAssertEqual(runtime.activity, .idle)
        XCTAssertTrue(f.storedIDs.isEmpty)
    }

    @MainActor
    func testCancelledIntentDoesNotSettleUserCapture() async throws {
        let f = try fixture()
        let gate = f.gate()
        var prepareCount = 0
        let chooser = f.configure { _, _, _ in
            prepareCount += 1
            try await gate.run()
            return f.prepared()
        }
        let runtime = chooser.runtime
        try chooser.start(.window)
        try await ack(gate.entered)
        XCTAssertEqual(runtime.activity, .selecting)
        let task = f.start {
            await Task.yield()
            return try await IntentHost.capture(.region, chooser: chooser,
                                                load: { try await f.store.load(id: $0).originalData })
        }
        task.cancel()
        do {
            _ = try await value(task)
            XCTFail("開始前にキャンセルされるはず")
        } catch {
            XCTAssertTrue(error is CancellationError, "想定外のエラー: \(error)")
        }
        XCTAssertEqual(runtime.activity, .selecting)
        XCTAssertEqual(prepareCount, 1)

        chooser.cancel()
        gate.finish(.failure(CancellationError()))
        await runtime.waitUntilIdle()
    }

    @MainActor
    func testLateCancellationDoesNotWithdrawAnotherCapture() async throws {
        let f = try fixture()
        let gate = f.gate()
        let chooser = f.configure { mode, _, _ in
            if mode == .window { try await gate.run() }
            return f.prepared()
        }
        let runtime = chooser.runtime
        let data = try await value(f.capture())
        try assertPNG(data)
        let outcome = try XCTUnwrap(runtime.deliveryOutcome)
        XCTAssertEqual(outcome.disposition, .exportRequested)
        let operationID = outcome.operationID

        let nextOperationID = try chooser.start(.window)
        try await ack(gate.entered)
        XCTAssertNotEqual(nextOperationID, operationID)
        XCTAssertEqual(runtime.activity, .selecting)

        IntentHost.withdraw(operationID: operationID, chooser: chooser)
        XCTAssertEqual(runtime.activity, .selecting)

        chooser.cancel()
        gate.finish(.failure(CancellationError()))
        await runtime.waitUntilIdle()
        XCTAssertEqual(runtime.activity, .idle)
    }

    @MainActor
    func testCaptureFlowKeepsItsResultWhenAnotherCaptureStartsBeforeReading() async throws {
        let f = try fixture()
        let gate = f.gate()
        let chooser = f.configure { mode, _, _ in
            if mode == .window { try await gate.run() }
            return f.prepared()
        }
        let runtime = chooser.runtime
        var nextOperationID: UUID?
        f.onActivity { activity in
            // The intent's capture has just finished; start another before the intent reads its result.
            if activity == .idle, nextOperationID == nil {
                nextOperationID = try? chooser.start(.window)
            }
        }
        let data = try await value(f.capture())
        try assertPNG(data)
        XCTAssertNotNil(nextOperationID)
        try await ack(gate.entered)
        XCTAssertEqual(runtime.activity, .selecting)
        chooser.cancel()
        gate.finish(.failure(CancellationError()))
        await runtime.waitUntilIdle()
    }

    @MainActor
    func testCaptureFlowReportsBusyWhenCaptureCannotStart() async throws {
        let f = try fixture()
        var prepareCount = 0
        let chooser = f.configure { _, _, _ in
            prepareCount += 1
            return f.prepared()
        }
        func expectBusy(_ message: String) async {
            do {
                _ = try await value(f.capture())
                XCTFail(message)
            } catch {
                XCTAssertEqual(error as? CaptureIntentError, .busy, message)
            }
        }
        chooser.mayShow = { false }
        await expectBusy("撮影を始められないときは busy になるはず")
        chooser.mayShow = { true }
        chooser.runtime.beginTermination()
        // Still idle, so the chooser's guard passes and the runtime rejects the start.
        XCTAssertEqual(chooser.runtime.activity, .idle)
        await expectBusy("終了処理中は busy になるはず")
        XCTAssertEqual(prepareCount, 0)
    }

    @MainActor
    func testCaptureFlowCancelsCountdownBeforeStartingNewCapture() async throws {
        let f = try fixture()
        var modes: [CaptureMode] = []
        let chooser = f.configure { mode, _, _ in
            modes.append(mode)
            return f.prepared()
        }
        try f.captureSettings.setTimerSeconds(3)
        let counting = XCTestExpectation(description: "User capture is counting down")
        counting.assertForOverFulfill = false
        f.onActivity { if case .countdown = $0 { counting.fulfill() } }
        try chooser.start(.window)
        try await ack(counting)
        // The running capture keeps its 3 s snapshot; the intent's capture uses no delay.
        try f.captureSettings.setTimerSeconds(0)
        let data = try await value(f.capture())
        try assertPNG(data)
        XCTAssertEqual(modes, [.window, .region])
        XCTAssertEqual(f.storedIDs.count, 1)
    }

    @MainActor
    func testCaptureFlowReportsPreparationFailure() async throws {
        let f = try fixture()
        _ = f.configure { _, _, _ in throw Injected.boom }
        do {
            _ = try await value(f.capture())
            XCTFail("Expected failed capture")
        } catch {
            guard case .failed(let message)? = error as? CaptureIntentError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("boom"))
        }
        XCTAssertTrue(f.storedIDs.isEmpty)
    }

    @MainActor
    func testCaptureFlowSettlesSelectingCaptureBeforeStartingNewCapture() async throws {
        let f = try fixture()
        let gate = f.gate()
        var modes: [CaptureMode] = []
        let chooser = f.configure { mode, _, _ in
            modes.append(mode)
            if modes.count == 1 { try await gate.run() }
            return f.prepared()
        }
        let runtime = chooser.runtime
        let firstID = try chooser.start(.window)
        try await ack(gate.entered)
        XCTAssertEqual(runtime.activity, .selecting)
        let cancelled = XCTestExpectation(description: "Selecting capture cancelled")
        f.onActivity { activity in
            if activity == .cancelling {
                cancelled.fulfill()
                gate.finish(.failure(CancellationError()))
            }
        }
        let task = f.capture()
        try await ack(cancelled)
        let data = try await value(task)
        try assertPNG(data)
        XCTAssertEqual(modes, [.window, .region])
        XCTAssertEqual(runtime.activity, .idle)
        let outcome = try XCTUnwrap(runtime.deliveryOutcome)
        XCTAssertNotEqual(outcome.operationID, firstID)
        XCTAssertEqual(outcome.disposition, .exportRequested)
        XCTAssertEqual(f.storedIDs, [outcome.documentID])
    }

    private enum Injected: LocalizedError {
        case boom, timeout
        var errorDescription: String? {
            switch self {
            case .boom: return "boom"
            case .timeout: return "Timed out waiting for capture"
            }
        }
    }

    @MainActor private func fixture() throws -> Fixture {
        let f = try Fixture()
        addTeardownBlock { await f.cleanup() }
        return f
    }

    @MainActor private func ack(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw Injected.timeout }
    }

    @MainActor private func value(_ task: Task<Data, Error>) async throws -> Data {
        let done = XCTestExpectation(description: "Capture intent completed")
        let observer = Task { let result = await task.result; done.fulfill(); return result }
        do { try await ack(done) }
        catch { task.cancel(); observer.cancel(); throw error }
        return try await observer.value.get()
    }

    private func assertPNG(_ data: Data) throws {
        XCTAssertEqual(Array(data.prefix(8)), [UInt8(137), 80, 78, 71, 13, 10, 26, 10])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
    }

    @MainActor private final class Gate {
        let entered = XCTestExpectation(description: "Capture preparation entered")
        private var pending: CheckedContinuation<Void, Error>?
        private var early: Result<Void, Error>?
        private var started = false

        func run() async throws {
            precondition(!started)
            started = true
            entered.fulfill()
            if let early { return try early.get() }
            try await withCheckedThrowingContinuation { pending = $0 }
        }

        func finish(_ result: Result<Void, Error>) {
            early = result
            let old = pending
            pending = nil
            old?.resume(with: result)
        }
    }

    @MainActor private final class Fixture {
        let suite = "getGamen.AppIntentsTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let pasteboard = NSPasteboard(name: .init("getGamen.test.\(UUID())"))
        let root: URL
        let store: DocumentStore
        let exports: AutomaticExportCoordinator
        let settings: ExportSettings
        let captureSettings: CaptureSettings
        let windows: EditorWindowCoordinator
        let image: CGImage
        var storedIDs: [UUID] = []
        private var gates: [Gate] = []
        private var chooser: CaptureChooserController?
        private var task: Task<Data, Error>?

        init() throws {
            _ = NSApplication.shared
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("getGamen-intents-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let output = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            store = try DocumentStore(root: root.appendingPathComponent("documents", isDirectory: true))
            exports = try AutomaticExportCoordinator(receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true))
            settings = ExportSettings(defaults: defaults, defaultFolder: root.appendingPathComponent("getGamen", isDirectory: true))
            try settings.setDestinationFolder(output)
            captureSettings = CaptureSettings(defaults: defaults)
            try captureSettings.setTimerSeconds(0)
            windows = EditorWindowCoordinator(store: store, exports: exports, settings: settings)
            let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
                                  255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255]
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            image = try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }

        func prepared(copiesToClipboard: Bool = false) -> PreparedCapture {
            let image = image
            return PreparedCapture(capture: { _ in
                CapturedImage(image: image, previousRecordError: nil, copiesToClipboard: copiesToClipboard)
            },
                                   cancel: {}, waitForCleanup: {})
        }

        func configure(
            prepare: @escaping @MainActor (CaptureMode, [NSWindow], HotKeyShortcut?) async throws -> PreparedCapture
        ) -> CaptureChooserController {
            let handoff = CapturedDocumentHandoff(store: store, editorWindows: windows, pasteboard: pasteboard,
                afterOriginalStored: { [weak self] document in self?.storedIDs.append(document.documentID) })
            let runtime = AppRuntime(captureSettings: captureSettings, exportSettings: settings,
                cancelShortcut: HotKeyShortcut(keyCode: 53, modifiers: 0), prepare: prepare, wait: { seconds, onRemaining in
                    // Report the countdown, then hold until cancelled; no test waits on real time.
                    guard seconds > 0 else { return }
                    onRemaining(seconds)
                    try await Task.sleep(for: .seconds(3600))
                }, handoff: handoff)
            let chooser = CaptureChooserController(runtime: runtime, defaults: defaults, route: { _ in })
            self.chooser = chooser
            return chooser
        }

        func gate() -> Gate {
            let gate = Gate()
            gates.append(gate)
            return gate
        }

        func start(_ operation: @escaping @MainActor () async throws -> Data) -> Task<Data, Error> {
            let task = Task { try await operation() }
            self.task = task
            return task
        }

        /// Runs the region capture intent against the configured chooser.
        func capture(load: ((UUID) async throws -> Data)? = nil) -> Task<Data, Error> {
            guard let chooser else { preconditionFailure("configure first") }
            let store = store
            return start {
                try await IntentHost.capture(.region, chooser: chooser,
                                             load: load ?? { try await store.load(id: $0).originalData })
            }
        }

        /// Observes activity after the chooser's own presentation hook.
        func onActivity(_ body: @escaping @MainActor (CaptureActivity) -> Void) {
            guard let runtime = chooser?.runtime else { preconditionFailure("configure first") }
            let previous = runtime.activityDidChange
            runtime.activityDidChange = { previous?($0); body($0) }
        }

        func cleanup() async {
            task?.cancel()
            chooser?.runtime.beginTermination()
            for gate in gates { gate.finish(.failure(CancellationError())) }
            let finished = XCTestExpectation(description: "Capture, editor and export teardown settled")
            let worker = Task {
                if let task { _ = await task.result }
                await chooser?.runtime.waitUntilIdle()
                for id in storedIDs {
                    if let host = windows.window(for: id)?.contentViewController as? NSHostingController<EditorView> {
                        await host.rootView.session.waitUntilIdle()
                    }
                    _ = try? await exports.waitUntilSettled(documentID: id)
                    windows.window(for: id)?.close()
                }
                finished.fulfill()
            }
            let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(result, .completed, "Finish workers before removing their files")
            guard result == .completed else { worker.cancel(); return }
            chooser?.window.close()
            chooser = nil
            task = nil
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
