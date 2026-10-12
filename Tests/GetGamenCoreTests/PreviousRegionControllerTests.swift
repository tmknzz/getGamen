import AppKit
import ScreenCaptureKit
import XCTest
@testable import GetGamenCore

final class PreviousRegionControllerTests: XCTestCase {
    @MainActor
    func testFreshLeaseRemembersOnlyAfterSuccessfulCaptureAndReopensWithoutOverlay() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let previous = try f.previous()
        let lease = try await f.fresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.record.path), "A completed drag is not a successful capture")
        let result = try await previous.capture(lease, showsCursor: false)
        XCTAssertNil(result.previousRecordError)
        XCTAssertEqual(result.image.width, 40)
        XCTAssertEqual(result.selection, lease.selection)
        XCTAssertEqual(try PreviousRegionRecordStore(fileURL: f.record).load(), lease.selection)
        let reopened = try f.previous()
        let repeated = try await reopened.preparePrevious()
        XCTAssertEqual(repeated.selection, lease.selection)
        XCTAssertEqual(repeated.pixelSize, PixelSize(width: 40, height: 20))
        XCTAssertEqual(f.presentations, 1)
        _ = try await repeated.capture(showsCursor: true)
        do { _ = try await repeated.capture(showsCursor: false); XCTFail("Previous lease reused") }
        catch { XCTAssertEqual(error as? PreviousRegionError, .staleRequest) }
    }

    @MainActor
    func testMissingCorruptAndUnknownVersionPrecedePermissionRequests() async throws {
        let f = try Fixture()
        defer { f.remove() }
        f.authorized = false
        let controller = try f.previous()
        do { _ = try await controller.preparePrevious(); XCTFail("Missing record accepted") }
        catch { XCTAssertEqual(error as? PreviousRegionError, .missingPrevious) }
        let cases: [(Data, PreviousRegionError)] = [
            (Data("broken".utf8), .corruptRecord),
            (Data("{\"schemaVersion\":99}".utf8), .unsupportedRecordVersion(99)),
            (Data("{\"schemaVersion\":1}".utf8), .corruptRecord)]
        for (bytes, expected) in cases {
            try bytes.write(to: f.record)
            do { _ = try await controller.preparePrevious(); XCTFail("Bad record accepted") }
            catch { XCTAssertEqual(error as? PreviousRegionError, expected) }
            XCTAssertEqual(try Data(contentsOf: f.record), bytes)
        }
        XCTAssertEqual(f.requests, 0)
        XCTAssertEqual(f.snapshots, 0)
        XCTAssertEqual(f.presentations, 0)
    }

    @MainActor
    func testSuccessfulFreshCaptureCanReplaceCorruptRecord() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try Data("not-json".utf8).write(to: f.record)
        let controller = try f.previous()
        let lease = try await f.fresh()
        let result = try await controller.capture(lease, showsCursor: false)
        XCTAssertNil(result.previousRecordError)
        XCTAssertEqual(try PreviousRegionRecordStore(fileURL: f.record).load(), lease.selection)
    }

    @MainActor
    func testWriteFailureReturnsGoodImageAndPreservesPriorRecordBytes() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.seed()
        let old = try Data(contentsOf: f.record)
        let expected = NSError(domain: "InjectedRememberWrite", code: 28)
        let controller = try PreviousRegionController(captureService: f.service, recordURL: f.record,
                                                      beforeAtomicWrite: { throw expected })
        let lease = try await f.fresh()
        let result = try await controller.capture(lease, showsCursor: false)
        XCTAssertEqual(result.image.width, 40)
        XCTAssertEqual(result.image.height, 20)
        XCTAssertEqual(result.selection, lease.selection)
        let error = try XCTUnwrap(result.previousRecordError) as NSError
        XCTAssertEqual(error.domain, expected.domain)
        XCTAssertEqual(error.code, expected.code)
        XCTAssertEqual(try Data(contentsOf: f.record), old)
    }

    @MainActor
    func testFreshNativeFailurePreservesPreviousBytes() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.seed()
        let old = try Data(contentsOf: f.record)
        f.captureBody = { _, _ in throw Injected.failed }
        let previous = try f.previous()
        let lease = try await f.fresh()
        do { _ = try await previous.capture(lease, showsCursor: false); XCTFail("Capture failure hidden") }
        catch { XCTAssertEqual(error as? Injected, .failed) }
        await previous.waitUntilIdle()
        XCTAssertEqual(try Data(contentsOf: f.record), old)
    }

    @MainActor
    func testPreviousResolvesNewRuntimeIDAndTranslationButRejectsChangedSignature() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.seed()
        let controller = try f.previous()
        f.displays = [screen(runtime: 91, x: 300, y: -200)]
        let lease = try await controller.preparePrevious()
        XCTAssertEqual(lease.pixelSize, PixelSize(width: 40, height: 20))
        let result = try await lease.capture(showsCursor: false)
        XCTAssertNil(result.previousRecordError)
        XCTAssertEqual(try PreviousRegionRecordStore(fileURL: f.record).load(), result.selection)
        let afterSuccess = try Data(contentsOf: f.record)
        XCTAssertEqual(f.presentations, 0)
        for changed in [[screen(scale: 1)], [screen(rotation: 90)], [screen(backingWidth: 199)], []] {
            f.displays = changed
            do { _ = try await controller.preparePrevious(); XCTFail("Changed topology accepted") }
            catch { XCTAssertEqual(error as? PreviousRegionError, .reselectionRequired(.topologyChanged)) }
            XCTAssertEqual(try Data(contentsOf: f.record), afterSuccess)
        }
    }

    @MainActor
    func testBusyDoesNotAdoptFreshLeaseOrCancelForeignServiceOwner() async throws {
        let f = try Fixture()
        let other = try Fixture()
        defer { f.remove(); other.remove() }
        try f.seed()
        let controller = try f.previous()
        let reserved = try await controller.preparePrevious()
        let foreignFresh = try await other.fresh()
        do { _ = try await controller.capture(foreignFresh, showsCursor: false); XCTFail("Busy wrapper accepted fresh lease") }
        catch { XCTAssertEqual(error as? PreviousRegionError, .busy) }
        _ = try await foreignFresh.capture(showsCursor: false)
        reserved.cancel()
        let foreignOwner = try await f.service.prepareExclusions(windows: [])
        do { _ = try await controller.preparePrevious(); XCTFail("Busy shared service accepted") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .busy) }
        controller.cancel()
        _ = try await f.service.capture(selection: f.selection(), exclusions: foreignOwner, showsCursor: false)
    }

    @MainActor
    func testCancelledPreparationAndMultipleCleanupWaitersObserveActualUnwind() async throws {
        for lateFailure in [false, true] {
            let f = try Fixture()
            defer { f.remove() }
            try f.seed()
            let old = try Data(contentsOf: f.record)
            let gate = Gate<RegionExclusionLease>()
            defer { gate.finish(.failure(Injected.failed)) }
            var nativeUnwound = false
            f.prepareBody = {
                defer { nativeUnwound = true }
                return try await gate.run()
            }
            let controller = try f.previous()
            let operation = Task { try await controller.preparePrevious() }
            defer { operation.cancel() }
            await gate.waitStarted()
            controller.cancel()
            let enteredA = XCTestExpectation(description: "Waiter A entered")
            let enteredB = XCTestExpectation(description: "Waiter B entered")
            let finished = XCTestExpectation(description: "Both cleanup observers finished")
            finished.expectedFulfillmentCount = 2
            let a = Task { @MainActor in
                enteredA.fulfill()
                await controller.waitUntilIdle()
                XCTAssertTrue(nativeUnwound, "Barrier must inspect cleanup at return, including canceled observers")
                finished.fulfill()
            }
            let b = Task { @MainActor in
                enteredB.fulfill()
                await controller.waitUntilIdle()
                XCTAssertTrue(nativeUnwound)
                finished.fulfill()
            }
            defer { a.cancel(); b.cancel() }
            let entered = await XCTWaiter.fulfillment(of: [enteredA, enteredB], timeout: 5)
            XCTAssertEqual(entered, .completed)
            a.cancel()
            do { _ = try await controller.preparePrevious(); XCTFail("Unwinding controller not busy") }
            catch { XCTAssertEqual(error as? PreviousRegionError, .busy) }
            if lateFailure { gate.finish(.failure(Injected.failed)) }
            else { gate.finish(.success(RegionExclusionLease(excludedWindows: [], validate: {}))) }
            do { _ = try await operation.value; XCTFail("Canceled preparation returned") }
            catch { XCTAssertTrue(error is CancellationError) }
            let observersFinished = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(observersFinished, .completed)
            guard observersFinished == .completed else { throw Injected.failed }
            XCTAssertTrue(nativeUnwound)
            XCTAssertEqual(try Data(contentsOf: f.record), old)
            f.prepareBody = nil
            let next = try await controller.preparePrevious()
            next.cancel()
            await controller.waitUntilIdle()
        }
    }

    @MainActor
    func testCancelledPreviousCaptureSuppressesLateSuccessAndErrorBeforeRemembering() async throws {
        for lateFailure in [false, true] {
            let f = try Fixture()
            defer { f.remove() }
            try f.seed()
            let old = try Data(contentsOf: f.record)
            let controller = try f.previous()
            let lease = try await controller.preparePrevious()
            let gate = Gate<CGImage>()
            defer { gate.finish(.failure(Injected.failed)) }
            var nativeUnwound = false
            f.captureBody = { _, _ in
                defer { nativeUnwound = true }
                return try await gate.run()
            }
            let capture = Task { try await lease.capture(showsCursor: false) }
            defer { capture.cancel() }
            await gate.waitStarted()
            lease.cancel()
            let entered = XCTestExpectation(description: "Capture cleanup observer entered")
            let finished = XCTestExpectation(description: "Capture cleanup observer finished")
            let barrier = Task { @MainActor in
                entered.fulfill()
                await controller.waitUntilIdle()
                XCTAssertTrue(nativeUnwound)
                finished.fulfill()
            }
            defer { barrier.cancel() }
            let observerStarted = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            XCTAssertEqual(observerStarted, .completed)
            if lateFailure { gate.finish(.failure(Injected.failed)) }
            else { gate.finish(.success(try image())) }
            do { _ = try await capture.value; XCTFail("Canceled capture remembered") }
            catch { XCTAssertTrue(error is CancellationError) }
            let observerFinished = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(observerFinished, .completed)
            guard observerFinished == .completed else { throw Injected.failed }
            XCTAssertEqual(try Data(contentsOf: f.record), old)
            f.captureBody = nil
            let next = try await controller.preparePrevious()
            lease.cancel()
            _ = try await next.capture(showsCursor: false)
        }
    }

    @MainActor
    func testFreshCaptureTaskCancellationKeepsOldRecordAndWaitsForPanelCleanup() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.seed()
        let old = try Data(contentsOf: f.record)
        let controller = try f.previous()
        let lease = try await f.fresh()
        let gate = Gate<CGImage>()
        defer { gate.finish(.failure(Injected.failed)) }
        f.captureBody = { _, _ in try await gate.run() }
        let capture = Task { try await controller.capture(lease, showsCursor: false) }
        defer { capture.cancel() }
        await gate.waitStarted()
        capture.cancel()
        gate.finish(.success(try image()))
        do { _ = try await capture.value; XCTFail("Task cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        await controller.waitUntilIdle()
        XCTAssertEqual(f.panelCloses, 1)
        XCTAssertEqual(try Data(contentsOf: f.record), old)
    }

    @MainActor
    func testUnusedPreviousLeaseAndControllerDestructionReleaseOwnedRequest() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.seed()
        var controller: PreviousRegionController? = try f.previous()
        var lease: PreviousRegionController.PreparedPrevious? = try await controller!.preparePrevious()
        let observeLease = { [weak lease] in lease }
        lease = nil
        XCTAssertNil(observeLease())
        await controller!.waitUntilIdle()
        let retained = try await controller!.preparePrevious()
        let observeController = { [weak controller] in controller }
        controller = nil
        XCTAssertNil(observeController())
        do { _ = try await retained.capture(showsCursor: false); XCTFail("Orphaned lease accepted") }
        catch { XCTAssertEqual(error as? PreviousRegionError, .staleRequest) }
        let next = try f.previous()
        let valid = try await next.preparePrevious()
        valid.cancel(); valid.cancel()
        await next.waitUntilIdle()
    }

    @MainActor
    func testPreparedRuntimeChangeAndUnsupportedInnerSchemaPreserveRecord() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.seed()
        let before = try Data(contentsOf: f.record)
        let gate = Gate<RegionExclusionLease>()
        defer { gate.finish(.failure(Injected.failed)) }
        f.prepareBody = { try await gate.run() }
        let controller = try f.previous()
        let operation = Task { try await controller.preparePrevious() }
        defer { operation.cancel() }
        await gate.waitStarted()
        f.displays = [screen(runtime: 77)]
        gate.finish(.success(RegionExclusionLease(excludedWindows: [], validate: {})))
        do { _ = try await operation.value; XCTFail("Runtime identity changed during preparation") }
        catch { XCTAssertEqual(error as? PreviousRegionError, .reselectionRequired(.topologyChanged)) }
        XCTAssertEqual(try Data(contentsOf: f.record), before)
        f.prepareBody = nil
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        var selection = try XCTUnwrap(json["selection"] as? [String: Any])
        selection["schemaVersion"] = 99
        json["selection"] = selection
        let unknown = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        try unknown.write(to: f.record)
        do { _ = try await controller.preparePrevious(); XCTFail("Unknown inner schema accepted") }
        catch { XCTAssertEqual(error as? PreviousRegionError, .reselectionRequired(.unsupportedVersion(99))) }
        XCTAssertEqual(try Data(contentsOf: f.record), unknown)
    }

    @MainActor
    func testCallerWindowDeduplicatedAndHiddenOnlyAfterPreparationNeverClosed() async throws {
        _ = NSApplication.shared
        let window = TrackedWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                   styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let f = try Fixture()
        defer { f.remove() }
        try f.seed()
        let gate = Gate<RegionExclusionLease>()
        defer { gate.finish(.failure(Injected.failed)) }
        f.prepareBody = { try await gate.run() }
        let controller = try f.previous()
        let operation = Task { try await controller.preparePrevious(excludingWindows: [window, window]) }
        defer { operation.cancel() }
        await gate.waitStarted()
        XCTAssertEqual(f.observedPreparationIDs, [ObjectIdentifier(window)])
        XCTAssertEqual(window.orderOutCount, 0)
        XCTAssertEqual(window.closeCount, 0)
        gate.finish(.success(RegionExclusionLease(excludedWindows: [], validate: {})))
        let lease = try await operation.value
        XCTAssertEqual(window.orderOutCount, 1)
        lease.cancel()
        await controller.waitUntilIdle()
        XCTAssertEqual(window.closeCount, 0)
    }

    private enum Injected: Error, Equatable { case failed }
    private func screen(runtime: UInt32 = 1, x: Double = -100, y: Double = 0, scale: Double = 2,
                        rotation: Double = 0, backingWidth: Int = 200) -> RegionDisplay {
        RegionDisplay(id: "A", runtimeID: runtime, frame: RegionRect(x: x, y: y, width: 100, height: 100), scale: scale,
                      rotation: rotation, backingWidth: backingWidth, backingHeight: 200)
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor private final class Fixture {
        let root: URL
        let record: URL
        var authorized = true
        var requests = 0
        var snapshots = 0
        var presentations = 0
        var observedPreparationIDs: [ObjectIdentifier] = []
        var panelCloses = 0
        var displays = [RegionDisplay(id: "A", runtimeID: 1, frame: RegionRect(x: -100, y: 0, width: 100, height: 100),
                                      scale: 2, rotation: 0, backingWidth: 200, backingHeight: 200)]
        var prepareBody: (() async throws -> RegionExclusionLease)?
        var captureBody: ((String, SCStreamConfiguration) async throws -> CGImage)?
        lazy var service = RegionCaptureService(dependencies: dependencies)
        lazy var region = RegionSelectionController(captureService: service, presentation: RegionSelectionPresentation(present: { [weak self] _, _, receive in
            guard let self else { throw CancellationError() }
            presentations += 1
            receive(.began(CGPoint(x: -90, y: 70)))
            receive(.ended(CGPoint(x: -70, y: 80)))
            return RegionSelectionPanels(windows: [], update: { _, _ in }, hide: {}, close: { [weak self] in self?.panelCloses += 1 })
        }))
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-previous-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            record = root.appendingPathComponent("previous-region.json")
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func previous() throws -> PreviousRegionController { try PreviousRegionController(captureService: service, recordURL: record) }
        func fresh() async throws -> RegionSelectionController.PreparedRegion {
            try await region.select(cancelShortcut: HotKeyShortcut(keyCode: 53, modifiers: 0))
        }
        func selection() throws -> RegionSelection {
            try RegionGeometry.select(drag: RegionRect(x: -90, y: 70, width: 20, height: 10), displays: displays)
        }
        func seed() throws { try PreviousRegionRecordStore(fileURL: record).remember(selection()) }
        var dependencies: RegionCaptureDependencies {
            RegionCaptureDependencies(preflight: { [weak self] in self?.authorized ?? false }, request: { [weak self] in
                guard let self else { return false }; requests += 1; return authorized
            },
                                      snapshot: { [weak self] in
                guard let self else { throw CancellationError() }
                snapshots += 1
                return RegionCaptureSnapshot(displays: displays, capture: { [weak self] id, _, configuration in
                    guard let self else { throw CancellationError() }
                    if let captureBody { return try await captureBody(id, configuration) }
                    let context = try XCTUnwrap(CGContext(data: nil, width: configuration.width, height: configuration.height,
                                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    return try XCTUnwrap(context.makeImage())
                })
            }, prepare: { [weak self] windows in
                guard let self else { throw CancellationError() }
                observedPreparationIDs = windows.map(ObjectIdentifier.init)
                if let prepareBody { return try await prepareBody() }
                return RegionExclusionLease(excludedWindows: [], validate: {})
            })
        }
    }

    @MainActor private final class Gate<Value> {
        private let startedExpectation = XCTestExpectation(description: "Controlled native dependency entered")
        private var started = false
        private var continuation: CheckedContinuation<Value, Error>?
        private var early: Result<Value, Error>?
        func run() async throws -> Value {
            precondition(!started)
            started = true
            startedExpectation.fulfill()
            if let early { return try early.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func waitStarted() async {
            if started { return }
            let result = await XCTWaiter.fulfillment(of: [startedExpectation], timeout: 5)
            XCTAssertEqual(result, .completed)
        }
        func finish(_ result: Result<Value, Error>) {
            early = result
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }

    @MainActor private final class TrackedWindow: NSWindow {
        var orderOutCount = 0
        var closeCount = 0
        override func orderOut(_ sender: Any?) { orderOutCount += 1; super.orderOut(sender) }
        override func close() { closeCount += 1; super.close() }
    }
}
