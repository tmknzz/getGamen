import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import XCTest
@testable import GetGamen
@testable import GetGamenCore

/// Real owned persistence/export/windows with synthetic capture pixels; no native screen capture.
final class CapturedDocumentHandoffTests: XCTestCase {
    @MainActor
    func testCopyOnlySkipsDocumentEditorAndExport() async throws {
        let f = try fixture()
        let pasteboard = NSPasteboard(name: .init("getGamen.test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        var presented = false
        f.windows.willPresentEditor = { presented = true }
        let handoff = f.handoff(pasteboard: pasteboard)
        var captured = try f.captured()
        captured.copiesToClipboard = true
        let copy = captured
        try await value(f.start { try await handoff.accept(copy, intent: f.intent(.png)) })
        XCTAssertTrue(f.storedIDs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.documents.path).isEmpty)
        XCTAssertEqual(f.loads, 0)
        XCTAssertFalse(presented)
        XCTAssertNil(handoff.outcome)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertEqual(try pixels(png), Self.expectedPixels)
    }

    @MainActor
    func testDisallowedCopyOnlyStillCreatesEditorAndCopiesSameImageAsCopyOnly() async throws {
        let f = try fixture()
        let pasteboard = NSPasteboard(name: .init("getGamen.test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let handoff = f.handoff(pasteboard: pasteboard)
        var intent = f.intent(.png)
        intent.allowsCopyOnly = false
        var captured = try f.captured()
        captured.copiesToClipboard = true
        let deliveryIntent = intent
        let copy = captured
        try await value(f.start { try await handoff.accept(copy, intent: deliveryIntent) })
        let outcome = try XCTUnwrap(handoff.outcome)
        XCTAssertEqual(f.storedIDs, [outcome.documentID])
        XCTAssertEqual(outcome.operationID, intent.id)
        XCTAssertEqual(outcome.disposition, .exportRequested)
        XCTAssertNotNil(f.windows.window(for: outcome.documentID))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        let status = try await settled(f, f.session(outcome.documentID))
        guard case .saved(_, 0, _) = status else { return XCTFail("Initial export did not finish") }
        // The copy-only path must put the same PNG on the pasteboard as copying from the editor.
        let copyBoard = NSPasteboard(name: .init("getGamen.test.\(UUID())"))
        defer { copyBoard.releaseGlobally() }
        let copyHandoff = f.handoff(pasteboard: copyBoard)
        let copyIntent = f.intent(.png)
        try await value(f.start { try await copyHandoff.accept(copy, intent: copyIntent) })
        XCTAssertEqual(try XCTUnwrap(copyBoard.data(forType: .png)), try XCTUnwrap(pasteboard.data(forType: .png)))
    }

    @MainActor
    func testActualPNGOriginalEditorAndSingleInitialExportThenViewingDoesNotExport() async throws {
        let f = try fixture()
        let handoff = f.handoff()
        let intent = f.intent(.png8)
        try await value(f.start { try await handoff.accept(f.captured(), intent: intent) })
        let outcome = try XCTUnwrap(handoff.outcome)
        XCTAssertEqual(outcome.operationID, intent.id)
        XCTAssertEqual(outcome.disposition, .exportRequested)
        let loaded = try await f.store.load(id: outcome.documentID)
        XCTAssertEqual(loaded.document.pixelSize, PixelSize(width: 3, height: 2))
        XCTAssertEqual(loaded.document.revision, 0)
        XCTAssertEqual(loaded.originalData, try RasterImageCodec.encode(f.image, format: .png))
        XCTAssertEqual(Array(loaded.originalData.prefix(8)), [UInt8(137), 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(try pixels(loaded.originalData), Self.expectedPixels)
        let session = try f.session(outcome.documentID)
        XCTAssertEqual(session.format, .png8)
        let first = try await settled(f, session)
        guard case .saved(_, 0, let url) = first else { return XCTFail("Actual initial export did not finish") }
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 25)
        if bytes.count > 25 { XCTAssertEqual(bytes[25], 3) }
        XCTAssertEqual(try pixels(bytes), Self.expectedPixels)
        let receipt = try await f.exports.existing(documentID: outcome.documentID, slot: .png)
        let reopened = try await f.windows.openEditor(documentID: outcome.documentID)
        XCTAssertTrue(reopened === session)
        try await value(f.start { await reopened.waitUntilIdle() })
        let after = await f.exports.status(documentID: outcome.documentID)
        let afterReceipt = try await f.exports.existing(documentID: outcome.documentID, slot: .png)
        XCTAssertEqual(after, first); XCTAssertEqual(afterReceipt, receipt)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let finalSource = try await f.store.load(id: outcome.documentID)
        XCTAssertEqual(finalSource.originalData, loaded.originalData)
    }

    @MainActor
    func testBeforeCreateCancellationAndRealCreateFailureNeverInventStoredOutcome() async throws {
        for cancel in [false, true] {
            let f = try fixture()
            let gate = f.gate()
            let handoff = f.handoff(beforeCreate: { try await gate.run() })
            let operation = f.start { try await handoff.accept(f.captured(), intent: f.intent(.png)) }
            try await gate.waitStarted()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.documents.path).isEmpty)
            XCTAssertTrue(f.storedIDs.isEmpty); XCTAssertNil(handoff.outcome)
            if cancel { operation.cancel() }
            else { try FileManager.default.removeItem(at: f.documents) }
            gate.finish(.success(()))
            do { try await value(operation); XCTFail("Expected cancelled or failing create") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain) }
            }
            XCTAssertNil(handoff.outcome)
            XCTAssertTrue(f.storedIDs.isEmpty)
            XCTAssertEqual(f.loads, 0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
        }
    }

    @MainActor
    func testPreCancelledAcceptDoesNotEvenReachCreateCheckpoint() async throws {
        let f = try fixture()
        var calls = 0
        let handoff = f.handoff(beforeCreate: { calls += 1 })
        let operation = f.start {
            withUnsafeCurrentTask { $0?.cancel() }
            try await handoff.accept(f.captured(), intent: f.intent(.png))
        }
        do { try await value(operation); XCTFail("Precancel ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0); XCTAssertNil(handoff.outcome)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.documents.path).isEmpty)
    }

    @MainActor
    func testCancellationAfterRealStoreRetainsOriginalAndOverridesLateCheckpointError() async throws {
        for lateFailure in [false, true] {
            let f = try fixture()
            let gate = f.gate()
            let handoff = f.handoff(afterOriginalStored: { _ in try await gate.run() })
            let intent = f.intent(.png)
            let operation = f.start { try await handoff.accept(f.captured(), intent: intent) }
            try await gate.waitStarted()
            let id = try XCTUnwrap(f.storedIDs.first)
            let before = try await f.store.load(id: id)
            XCTAssertEqual(try pixels(before.originalData), Self.expectedPixels)
            XCTAssertNil(f.windows.window(for: id))
            operation.cancel()
            gate.finish(lateFailure ? .failure(Injected.failed) : .success(()))
            do { try await value(operation); XCTFail("Cancelled stored capture opened") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(handoff.outcome, CaptureDeliveryOutcome(operationID: intent.id, documentID: id, disposition: .retainedAfterCancellation))
            let after = try await f.store.load(id: id)
            let status = await f.exports.status(documentID: id)
            XCTAssertEqual(after, before); XCTAssertEqual(status, .idle)
            XCTAssertNil(f.windows.window(for: id)); XCTAssertEqual(f.loads, 0)
        }
    }

    @MainActor
    func testCancellationDuringActualEditorLoadNeverPresentsAndSuppressesLateLoadError() async throws {
        for lateFailure in [false, true] {
            let f = try fixture()
            let gate = f.gate()
            f.beforeLoad = { try await gate.run() }
            let handoff = f.handoff()
            let intent = f.intent(.png)
            let operation = f.start { try await handoff.accept(f.captured(), intent: intent) }
            try await gate.waitStarted()
            let id = try XCTUnwrap(f.storedIDs.first)
            XCTAssertNil(f.windows.window(for: id))
            operation.cancel()
            gate.finish(lateFailure ? .failure(Injected.failed) : .success(()))
            do { try await value(operation); XCTFail("Cancelled editor load presented") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(f.windows.window(for: id))
            XCTAssertEqual(handoff.outcome?.disposition, .retainedAfterCancellation)
            let stored = try await f.store.load(id: id)
            let status = await f.exports.status(documentID: id)
            XCTAssertEqual(try pixels(stored.originalData), Self.expectedPixels)
            XCTAssertEqual(status, .idle)
        }
    }

    @MainActor
    func testUncancelledPostStoreAndEditorLoadFailuresReportRetainedDocument() async throws {
        for duringLoad in [false, true] {
            let f = try fixture()
            if duringLoad { f.beforeLoad = { throw Injected.failed } }
            let handoff = f.handoff(afterOriginalStored: { _ in if !duringLoad { throw Injected.failed } })
            let operation = f.start { try await handoff.accept(f.captured(), intent: f.intent(.png)) }
            do { try await value(operation); XCTFail("Real post-store failure hidden") }
            catch { XCTAssertEqual(error as? Injected, .failed) }
            let outcome = try XCTUnwrap(handoff.outcome)
            guard case .retainedAfterFailure(let message) = outcome.disposition else { return XCTFail("Missing retained failure outcome") }
            XCTAssertFalse(message.isEmpty)
            let stored = try await f.store.load(id: outcome.documentID)
            XCTAssertEqual(stored.originalData, try RasterImageCodec.encode(f.image, format: .png))
            XCTAssertNil(f.windows.window(for: outcome.documentID))
            let status = await f.exports.status(documentID: outcome.documentID)
            XCTAssertEqual(status, .idle)
        }
    }

    @MainActor
    func testFrozenFormatQualityAndDestinationSurvivePreferenceChange() async throws {
        for format in [ExportFormat.png8, .jpeg] {
            let f = try fixture()
            let gate = f.gate()
            let handoff = f.handoff(afterOriginalStored: { _ in try await gate.run() })
            let intent = f.intent(format, quality: 0.2)
            let operation = f.start { try await handoff.accept(f.captured(), intent: intent) }
            try await gate.waitStarted()
            f.settings.setFormat(.png)
            try f.settings.setJPEGQuality(0.95)
            try f.settings.setDestinationFolder(f.otherOutput)
            gate.finish(.success(()))
            try await value(operation)
            let id = try XCTUnwrap(handoff.outcome?.documentID)
            let session = try f.session(id)
            XCTAssertEqual(session.format, format)
            let status = try await settled(f, session)
            guard case .saved(_, 0, let url) = status else { return XCTFail("Frozen export did not finish") }
            XCTAssertEqual(url.deletingLastPathComponent().path, f.output.path)
            let stored = try await f.store.load(id: id)
            let rendered = try EditRenderer.render(originalData: stored.originalData, pixelSize: stored.document.pixelSize, edits: EditState())
            let expected = try RasterImageCodec.encode(rendered, format: format.codecFormat(jpegQuality: 0.2))
            if format == .jpeg {
                let changedQuality = try RasterImageCodec.encode(rendered, format: .jpeg(quality: 0.95))
                XCTAssertNotEqual(expected, changedQuality, "Fixture must distinguish frozen and changed JPEG quality")
            } else {
                XCTAssertGreaterThan(expected.count, 25)
                if expected.count > 25 { XCTAssertEqual(expected[25], 3) }
            }
            XCTAssertEqual(try Data(contentsOf: url), expected)
            let after = try await f.store.load(id: id)
            XCTAssertEqual(after.originalData, stored.originalData)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.otherOutput.path).isEmpty)
        }
    }

    @MainActor
    func testMissingConfiguredExportDestinationKeepsRealEditorAndOriginal() async throws {
        let f = try fixture()
        let missing = f.root.appendingPathComponent("missing", isDirectory: true)
        let handoff = f.handoff()
        let intent = CaptureIntent(id: UUID(), mode: .region, capture: f.captureSettings.snapshot,
            export: ExportSettingsSnapshot(format: .png, jpegQuality: 0.9, destination: .configuredFolder(missing)), cancelShortcut: f.binding)
        try await value(f.start { try await handoff.accept(f.captured(), intent: intent) })
        let outcome = try XCTUnwrap(handoff.outcome)
        XCTAssertEqual(outcome.disposition, .exportRequested, "Outcome means enqueued, not saved output")
        let session = try f.session(outcome.documentID)
        try await value(f.start { await session.waitUntilIdle() })
        if case .exportPreparation(let error)? = session.issue { XCTAssertEqual(error as? ExportSettingsError, .destinationUnavailable) }
        else { XCTFail("Missing destination failure not surfaced") }
        XCTAssertTrue(try XCTUnwrap(f.windows.window(for: outcome.documentID)).isVisible)
        let stored = try await f.store.load(id: outcome.documentID)
        let status = await f.exports.status(documentID: outcome.documentID)
        XCTAssertEqual(try pixels(stored.originalData), Self.expectedPixels)
        XCTAssertEqual(status, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    @MainActor
    func testRuntimeRealHandoffRetainsPreciseOutcomeAndWarningUntilActualCleanup() async throws {
        let f = try fixture()
        let storedGate = f.gate(); let cleanupGate = f.gate()
        var cleanupFinished = false
        let handoff = f.handoff(afterOriginalStored: { _ in try await storedGate.run() })
        let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.settings, cancelShortcut: f.binding,
            prepare: { _, _, _ in PreparedCapture(capture: { _ in try f.captured(warning: Injected.warning) }, cancel: {}, waitForCleanup: {
                do { try await cleanupGate.run() } catch {}
                cleanupFinished = true
            }) }, handoff: handoff)
        let operationID = try runtime.startCapture(.region)
        f.trackRuntime(runtime)
        try await storedGate.waitStarted()
        let id = try XCTUnwrap(f.storedIDs.first)
        XCTAssertEqual(runtime.activity, .delivering)
        XCTAssertNotNil(runtime.previousRecordWarning)
        runtime.cancelCapture()
        XCTAssertThrowsError(try runtime.startCapture(.window)) { XCTAssertEqual($0 as? CaptureOperationError, .busy) }
        storedGate.finish(.failure(Injected.failed))
        try await cleanupGate.waitStarted()
        XCTAssertEqual(runtime.activity, .cancelling)
        XCTAssertEqual(runtime.deliveryOutcome, CaptureDeliveryOutcome(operationID: operationID, documentID: id, disposition: .retainedAfterCancellation))
        XCTAssertThrowsError(try runtime.startCapture(.previous)) { XCTAssertEqual($0 as? CaptureOperationError, .busy) }
        XCTAssertEqual(runtime.deliveryOutcome?.documentID, id, "Busy rejection must preserve the known retained outcome")
        let entered = XCTestExpectation(description: "Runtime idle observer entered")
        let observer = f.start {
            entered.fulfill(); await runtime.waitUntilIdle()
            XCTAssertTrue(cleanupFinished)
            XCTAssertEqual(runtime.activity, .idle)
        }
        try await ack(entered)
        observer.cancel()
        cleanupGate.finish(.success(()))
        try await value(observer)
        XCTAssertNil(runtime.failureMessage)
        XCTAssertNotNil(runtime.previousRecordWarning)
        XCTAssertEqual(runtime.deliveryOutcome?.disposition, .retainedAfterCancellation)
        XCTAssertThrowsError(try runtime.startCapture(.scroll)) { XCTAssertEqual($0 as? CaptureOperationError, .unsupportedMode(.scroll)) }
        XCTAssertEqual(runtime.deliveryOutcome?.documentID, id, "Rejected start must not reset retained outcome")
        let retained = try await f.store.load(id: id)
        XCTAssertEqual(try pixels(retained.originalData), Self.expectedPixels)
        XCTAssertNil(f.windows.window(for: id))
    }

    @MainActor
    func testRuntimeAcceptedNewOperationResetsPriorOutcomeBeforePreparing() async throws {
        let f = try fixture()
        let handoff = f.handoff()
        let nextGate = f.gate()
        var count = 0
        let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.settings, cancelShortcut: f.binding,
            prepare: { _, _, _ in
                count += 1
                if count == 2 { try await nextGate.run() }
                return PreparedCapture(capture: { _ in try f.captured() }, cancel: {}, waitForCleanup: {})
            }, handoff: handoff)
        try runtime.startCapture(.window)
        f.trackRuntime(runtime)
        try await value(f.start { await runtime.waitUntilIdle() })
        let first = try XCTUnwrap(runtime.deliveryOutcome)
        _ = try await settled(f, f.session(first.documentID))
        try runtime.startCapture(.region)
        f.trackRuntime(runtime)
        XCTAssertNil(runtime.deliveryOutcome)
        try await nextGate.waitStarted()
        runtime.cancelCapture(); nextGate.finish(.failure(Injected.failed))
        try await value(f.start { await runtime.waitUntilIdle() })
        XCTAssertNil(runtime.deliveryOutcome)
        let loaded = try await f.store.load(id: first.documentID)
        XCTAssertEqual(loaded.document.revision, 0)
    }

    private enum Injected: Error, Equatable { case failed, warning, timeout }
    private static let expectedPixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
                                                 255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255]
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
    @MainActor private func value<Value>(_ task: Task<Value, Error>) async throws -> Value {
        let done = XCTestExpectation(description: "Handoff caller completed")
        let observer = Task { let value = await task.result; done.fulfill(); return value }
        do { try await ack(done) } catch { task.cancel(); observer.cancel(); throw error }
        return try await observer.value.get()
    }
    @MainActor private func settled(_ f: Fixture, _ session: EditorSession) async throws -> ExportStatus {
        try await value(f.start { await session.waitUntilIdle() })
        return try await value(f.start { try await f.exports.waitUntilSettled(documentID: session.documentID) })
    }
    private func pixels(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3); XCTAssertEqual(image.height, 2)
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }
    @MainActor private final class Gate {
        let entered = XCTestExpectation(description: "Real handoff checkpoint entered")
        private var started = false
        private var pending: CheckedContinuation<Void, Error>?
        private var early: Result<Void, Error>?
        func run() async throws {
            precondition(!started); started = true; entered.fulfill()
            if let early { return try early.get() }
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        func waitStarted() async throws {
            if started { return }
            let result = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            XCTAssertEqual(result, .completed)
            guard result == .completed else { finish(.failure(Injected.failed)); throw Injected.timeout }
        }
        func finish(_ result: Result<Void, Error>) { early = result; let old = pending; pending = nil; old?.resume(with: result) }
    }
    @MainActor private final class Fixture {
        let suite = "getGamen.HandoffTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL; let documents: URL; let output: URL; let otherOutput: URL
        let store: DocumentStore; let exports: AutomaticExportCoordinator
        let settings: ExportSettings; let captureSettings: CaptureSettings
        let binding = HotKeyShortcut(keyCode: 53, modifiers: 0)
        let image: CGImage
        var storedIDs: [UUID] = []
        var beforeLoad: (() async throws -> Void)?
        var loads = 0
        private var gates: [Gate] = []
        private var taskCompletions: [XCTestExpectation] = []
        private var taskCancellations: [() -> Void] = []
        lazy var windows = EditorWindowCoordinator(store: store, exports: exports, settings: settings, beforeLoad: { [weak self] in
            guard let self else { throw CancellationError() }; loads += 1
            try await beforeLoad?()
        })
        init() throws {
            _ = NSApplication.shared
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-handoff-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            documents = root.appendingPathComponent("documents", isDirectory: true)
            output = root.appendingPathComponent("output", isDirectory: true)
            otherOutput = root.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: otherOutput, withIntermediateDirectories: false)
            store = try DocumentStore(root: documents)
            exports = try AutomaticExportCoordinator(receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true))
            settings = ExportSettings(defaults: defaults, defaultFolder: root.appendingPathComponent("getGamen", isDirectory: true))
            try settings.setDestinationFolder(output)
            captureSettings = CaptureSettings(defaults: defaults)
            let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
                                  255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255]
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            image = try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        func captured(warning: Error? = nil) throws -> CapturedImage { CapturedImage(image: image, previousRecordError: warning) }
        func intent(_ format: ExportFormat, quality: Double = 0.9) -> CaptureIntent {
            CaptureIntent(id: UUID(), mode: .region, capture: captureSettings.snapshot,
                export: ExportSettingsSnapshot(format: format, jpegQuality: quality, destination: .configuredFolder(output)), cancelShortcut: binding)
        }
        func handoff(pasteboard: NSPasteboard = .general,
                     beforeCreate: @escaping @MainActor () async throws -> Void = {},
                     afterOriginalStored: @escaping @MainActor (EditDocument) async throws -> Void = { _ in }) -> CapturedDocumentHandoff {
            CapturedDocumentHandoff(store: store, editorWindows: windows, pasteboard: pasteboard, beforeCreate: beforeCreate, afterOriginalStored: { [weak self] document in
                self?.storedIDs.append(document.documentID)
                try await afterOriginalStored(document)
            })
        }
        func gate() -> Gate { let value = Gate(); gates.append(value); return value }
        func start<Value>(_ operation: @escaping @MainActor () async throws -> Value) -> Task<Value, Error> {
            let task = Task { try await operation() }
            let finished = XCTestExpectation(description: "Tracked handoff work finished")
            taskCompletions.append(finished); taskCancellations.append { task.cancel() }
            Task { _ = await task.result; finished.fulfill() }
            return task
        }
        func session(_ id: UUID) throws -> EditorSession {
            let window = try XCTUnwrap(windows.window(for: id))
            return try XCTUnwrap(window.contentViewController as? NSHostingController<EditorView>).rootView.session
        }
        func trackRuntime(_ runtime: AppRuntime) {
            let finished = XCTestExpectation(description: "Tracked runtime cleanup finished")
            taskCompletions.append(finished)
            taskCancellations.append { [weak runtime] in runtime?.cancelCapture() }
            Task { await runtime.waitUntilIdle(); finished.fulfill() }
        }
        func cleanup() async {
            for cancel in taskCancellations { cancel() }
            for gate in gates { gate.finish(.failure(Injected.failed)) }
            if !taskCompletions.isEmpty {
                let result = await XCTWaiter.fulfillment(of: taskCompletions, timeout: 5)
                XCTAssertEqual(result, .completed, "Finish tracked workers before removing their files")
                guard result == .completed else { return }
            }
            for id in storedIDs {
                if let host = windows.window(for: id)?.contentViewController as? NSHostingController<EditorView> {
                    let session = host.rootView.session
                    let finished = XCTestExpectation(description: "Actual session/export teardown settled")
                    let exports = exports
                    let worker = Task {
                        await session.waitUntilIdle()
                        _ = try? await exports.waitUntilSettled(documentID: id)
                        finished.fulfill()
                    }
                    let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
                    XCTAssertEqual(result, .completed)
                    guard result == .completed else { worker.cancel(); return }
                }
                windows.window(for: id)?.close()
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
