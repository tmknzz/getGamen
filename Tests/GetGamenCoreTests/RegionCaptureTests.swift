import AppKit
import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import GetGamenCore

/// Synthetic transport exercises production orchestration; it is not native screen-capture evidence.
final class RegionCaptureTests: XCTestCase {
    @MainActor
    func testPermissionChecksNeverImplicitlyRequestAndExplicitRequestRereadsTruth() async throws {
        let fixture = Fixture()
        fixture.authorized = false
        fixture.requestResult = true
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        do { _ = try await service.snapshot(); XCTFail("Permission required") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .permissionRequired) }
        do { _ = try await service.prepareExclusions(windows: []); XCTFail("Permission required") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .permissionRequired) }
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(fixture.snapshots, 0)
        XCTAssertEqual(fixture.preparations, 0)
        XCTAssertFalse(service.requestAuthorizationForUserAction(), "Request return alone cannot grant effective permission")
        XCTAssertEqual(fixture.requests, 1)
        fixture.grantOnRequest = true
        fixture.requestResult = false
        XCTAssertTrue(service.requestAuthorizationForUserAction(), "Effective reread is authoritative")
        XCTAssertEqual(fixture.requests, 2)
        XCTAssertTrue(service.requestAuthorizationForUserAction())
        XCTAssertEqual(fixture.requests, 2)
        let handle = try await service.prepareExclusions(windows: [])
        fixture.authorized = false
        do { _ = try await service.capture(selection: fixture.selection(), exclusions: handle, showsCursor: false); XCTFail("Revocation ignored") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .permissionRequired) }
        XCTAssertEqual(fixture.requests, 2)
        XCTAssertTrue(fixture.captures.isEmpty)
        service.cancel()
    }

    @MainActor
    func testScopedReservationIsNotGivenToBusyCallerAndOldCancelCannotAffectNewHandle() async throws {
        let fixture = Fixture()
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        var firstCancel: (@MainActor () -> Void)?
        _ = try await service.prepareExclusions(windows: [], onAcquired: { firstCancel = $0 })
        var busyAcquired = false
        do {
            _ = try await service.prepareExclusions(windows: [], onAcquired: { _ in busyAcquired = true })
            XCTFail("Second owner reserved busy service")
        } catch { XCTAssertEqual(error as? RegionCaptureError, .busy) }
        XCTAssertFalse(busyAcquired)
        try XCTUnwrap(firstCancel)()
        let fresh = try await service.prepareExclusions(windows: [])
        firstCancel?()
        let image = try await service.capture(selection: fixture.selection(), exclusions: fresh, showsCursor: false)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(fixture.captures.count, 1)
    }

    @MainActor
    func testSnapshotDoesNotConsumePreparedHandleAndConfigurationUsesNativeSource() async throws {
        let fixture = Fixture()
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        let handle = try await service.prepareExclusions(windows: [])
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot, fixture.displays)
        let image = try await service.capture(selection: fixture.selection(), exclusions: handle, showsCursor: true)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 20)
        let call = try XCTUnwrap(fixture.captures.first)
        XCTAssertEqual(call.displayID, "A")
        XCTAssertEqual(call.excludedCount, 0)
        XCTAssertEqual(call.source, CGRect(x: 10, y: 20, width: 20, height: 10))
        XCTAssertEqual(call.width, 40)
        XCTAssertEqual(call.height, 20)
        XCTAssertTrue(call.cursor)
        XCTAssertFalse(call.audio)
        do { _ = try await service.capture(selection: fixture.selection(), exclusions: handle, showsCursor: false); XCTFail("Reused handle accepted") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .invalidExclusions) }
        XCTAssertEqual(fixture.captures.count, 1)
    }

    @MainActor
    func testCancelledSnapshotPrioritizesCancellationAndPreservesPreparedHandle() async throws {
        let fixture = Fixture()
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        let handle = try await service.prepareExclusions(windows: [])
        let gate = Gate<RegionCaptureSnapshot>()
        defer { gate.finish(.failure(TestError.injected)) }
        fixture.snapshotOverride = { try await gate.run() }
        let pending = Task { try await service.snapshot() }
        await gate.waitUntilStarted()
        pending.cancel()
        let nativeError = NSError(domain: "DelayedSnapshot", code: 73)
        gate.finish(.failure(nativeError))
        do { _ = try await pending.value; XCTFail("Late native error replaced cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }

        fixture.snapshotOverride = nil
        fixture.snapshotError = nativeError
        do { _ = try await service.snapshot(); XCTFail("Noncancelled native error swallowed") }
        catch {
            XCTAssertEqual((error as NSError).domain, nativeError.domain)
            XCTAssertEqual((error as NSError).code, nativeError.code)
        }
        fixture.snapshotError = nil
        _ = try await service.capture(selection: fixture.selection(), exclusions: handle, showsCursor: false)
        XCTAssertEqual(fixture.captures.count, 1, "Standalone snapshots must not consume an owned preparation")
    }

    @MainActor
    func testForeignHandleDoesNotConsumeEitherOwnersOwnHandle() async throws {
        let fixture = Fixture()
        let otherFixture = Fixture()
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        let other = RegionCaptureService(dependencies: otherFixture.dependencies)
        let ownHandle = try await service.prepareExclusions(windows: [])
        let otherHandle = try await other.prepareExclusions(windows: [])
        do { _ = try await other.capture(selection: fixture.selection(), exclusions: ownHandle, showsCursor: false); XCTFail("Foreign handle accepted") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .invalidExclusions) }
        _ = try await other.capture(selection: otherFixture.selection(), exclusions: otherHandle, showsCursor: false)
        _ = try await service.capture(selection: fixture.selection(), exclusions: ownHandle, showsCursor: false)
        XCTAssertEqual(fixture.captures.count, 1)
        XCTAssertEqual(otherFixture.captures.count, 1)
    }

    @MainActor
    func testCancelDuringPreparationSuppressesLateLeaseAndPreservesNewRequest() async throws {
        for fails in [false, true] {
            let fixture = Fixture()
            let gate = Gate<RegionExclusionLease>()
            defer { gate.finish(.failure(TestError.injected)) }
            fixture.prepareOverride = { try await gate.run() }
            let service = RegionCaptureService(dependencies: fixture.dependencies)
            var cancelOld: (@MainActor () -> Void)?
            let first = Task { try await service.prepareExclusions(windows: [], onAcquired: { cancelOld = $0 }) }
            await gate.waitUntilStarted()
            try XCTUnwrap(cancelOld)()
            fixture.prepareOverride = nil
            let fresh = try await service.prepareExclusions(windows: [])
            if fails { gate.finish(.failure(TestError.injected)) }
            else { gate.finish(.success(RegionExclusionLease(excludedWindows: [], validate: {}))) }
            do { _ = try await first.value; XCTFail("Late preparation published") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelOld?()
            _ = try await service.capture(selection: fixture.selection(), exclusions: fresh, showsCursor: false)
            XCTAssertEqual(fixture.captures.count, 1)
        }
    }

    @MainActor
    func testLateCaptureSuccessAndErrorCannotPublishOrCancelNewPreparedRequest() async throws {
        for fails in [false, true] {
            let fixture = Fixture()
            let gate = Gate<CGImage>()
            defer { gate.finish(.failure(TestError.injected)) }
            fixture.captureOverride = { _, _ in try await gate.run() }
            let service = RegionCaptureService(dependencies: fixture.dependencies)
            var cancelOld: (@MainActor () -> Void)?
            let old = try await service.prepareExclusions(windows: [], onAcquired: { cancelOld = $0 })
            let selection = try fixture.selection()
            let task = Task { try await service.capture(selection: selection, exclusions: old, showsCursor: false) }
            await gate.waitUntilStarted()
            cancelOld?()
            fixture.captureOverride = nil
            let fresh = try await service.prepareExclusions(windows: [])
            if fails { gate.finish(.failure(TestError.injected)) }
            else { gate.finish(.success(try raster(width: 40, height: 20))) }
            do { _ = try await task.value; XCTFail("Late capture published") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelOld?()
            _ = try await service.capture(selection: selection, exclusions: fresh, showsCursor: false)
            XCTAssertEqual(fixture.captures.count, 2)
        }
    }

    @MainActor
    func testRuntimeIDAndGeometryChangesDuringCaptureRejectWholeAttempt() async throws {
        for runtimeOnly in [true, false] {
            let fixture = Fixture()
            let originalSelection = try fixture.selection()
            let gate = Gate<CGImage>()
            defer { gate.finish(.failure(TestError.injected)) }
            fixture.captureOverride = { _, _ in try await gate.run() }
            let service = RegionCaptureService(dependencies: fixture.dependencies)
            let handle = try await service.prepareExclusions(windows: [])
            let task = Task { try await service.capture(selection: originalSelection, exclusions: handle, showsCursor: false) }
            await gate.waitUntilStarted()
            fixture.displays = [screen(runtimeID: runtimeOnly ? 9 : 1, x: -100, scale: runtimeOnly ? 2 : 1)]
            gate.finish(.success(try raster(width: 40, height: 20)))
            do { _ = try await task.value; XCTFail("Changed topology published") }
            catch { XCTAssertEqual(error as? RegionGeometryError, .topologyChanged) }
            XCTAssertEqual(fixture.captures.count, 1)
        }
    }

    @MainActor
    func testReconnectedRuntimeIDIsAllowedBeforeAttempt() async throws {
        let fixture = Fixture()
        let selection = try fixture.selection()
        fixture.displays = [screen(runtimeID: 91, x: -100, scale: 2)]
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        let handle = try await service.prepareExclusions(windows: [])
        _ = try await service.capture(selection: selection, exclusions: handle, showsCursor: false)
        XCTAssertEqual(fixture.captures.map(\.displayID), ["A"])
    }

    @MainActor
    func testWrongImageSizeAndNativeFailureNeverReturnAnImage() async throws {
        for wrongSize in [true, false] {
            let fixture = Fixture()
            let nativeError = NSError(domain: "InjectedScreenCapture", code: -3815)
            fixture.captureOverride = { _, _ in
                if wrongSize { return try self.raster(width: 39, height: 20) }
                throw nativeError
            }
            let service = RegionCaptureService(dependencies: fixture.dependencies)
            let handle = try await service.prepareExclusions(windows: [])
            do { _ = try await service.capture(selection: fixture.selection(), exclusions: handle, showsCursor: false); XCTFail("Invalid capture returned") }
            catch {
                if wrongSize { XCTAssertEqual(error as? RegionCaptureError, .invalidImage) }
                else { XCTAssertEqual((error as NSError).domain, nativeError.domain); XCTAssertEqual((error as NSError).code, nativeError.code) }
            }
            fixture.captureOverride = nil
            let retry = try await service.prepareExclusions(windows: [])
            _ = try await service.capture(selection: fixture.selection(), exclusions: retry, showsCursor: false)
        }
    }

    @MainActor
    func testAllTilesRequiredAndSecondTileFailureCannotReturnPartialCanvas() async throws {
        for fails in [false, true] {
            let fixture = Fixture()
            fixture.displays = [screen(x: 0, scale: 1), screen(id: "B", runtimeID: 2, x: 100, scale: 2)]
            let selection = try RegionGeometry.select(drag: RegionRect(x: 90, y: 20, width: 20, height: 10), displays: fixture.displays)
            let secondTile = Gate<CGImage>()
            defer { secondTile.finish(.failure(TestError.injected)) }
            fixture.captureOverride = { id, configuration in
                if id == "B" { return try await secondTile.run() }
                return try self.raster(width: configuration.width, height: configuration.height)
            }
            let service = RegionCaptureService(dependencies: fixture.dependencies)
            let handle = try await service.prepareExclusions(windows: [])
            var published = false
            let task = Task {
                let image = try await service.capture(selection: selection, exclusions: handle, showsCursor: false)
                published = true
                return image
            }
            await secondTile.waitUntilStarted()
            XCTAssertFalse(published)
            XCTAssertEqual(fixture.captures.map(\.displayID), ["A", "B"])
            XCTAssertEqual(fixture.captures[0].width, 10)
            XCTAssertEqual(fixture.captures[1].width, 20)
            if fails { secondTile.finish(.failure(TestError.injected)) }
            else { secondTile.finish(.success(try raster(width: 20, height: 20))) }
            do {
                let result = try await task.value
                XCTAssertFalse(fails)
                XCTAssertEqual(result.width, 40)
                XCTAssertEqual(result.height, 20)
            } catch { XCTAssertTrue(fails); XCTAssertEqual(error as? TestError, .injected) }
            XCTAssertEqual(published, !fails)
        }
    }

    @MainActor
    func testSnapshotAndExclusionValidationFailuresArePropagatedWithoutCapture() async throws {
        let fixture = Fixture()
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        fixture.snapshotError = TestError.injected
        do { _ = try await service.snapshot(); XCTFail("Snapshot error swallowed") }
        catch { XCTAssertEqual(error as? TestError, .injected) }
        fixture.snapshotError = nil
        fixture.prepareError = RegionCaptureError.missingExcludedWindow(42)
        do { _ = try await service.prepareExclusions(windows: []); XCTFail("Missing exclusion swallowed") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .missingExcludedWindow(42)) }
        fixture.prepareError = nil
        let handle = try await service.prepareExclusions(windows: [])
        fixture.validationError = RegionCaptureError.invalidExclusions
        do { _ = try await service.capture(selection: fixture.selection(), exclusions: handle, showsCursor: false); XCTFail("Invalid retained window accepted") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .invalidExclusions) }
        XCTAssertTrue(fixture.captures.isEmpty)
    }

    @MainActor
    func testCancellationOfCaptureTaskSuppressesNativeCompletion() async throws {
        let fixture = Fixture()
        let gate = Gate<CGImage>()
        defer { gate.finish(.failure(TestError.injected)) }
        fixture.captureOverride = { _, _ in try await gate.run() }
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        let handle = try await service.prepareExclusions(windows: [])
        let selection = try fixture.selection()
        let task = Task { try await service.capture(selection: selection, exclusions: handle, showsCursor: false) }
        await gate.waitUntilStarted()
        task.cancel()
        gate.finish(.success(try raster(width: 40, height: 20)))
        do { _ = try await task.value; XCTFail("Canceled capture returned image") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testAlreadyCancelledCaptureReleasesOnlyItsValidReservation() async throws {
        let fixture = Fixture()
        let service = RegionCaptureService(dependencies: fixture.dependencies)
        let handle = try await service.prepareExclusions(windows: [])
        let selection = try fixture.selection()
        let cancelled = Task { try await service.capture(selection: selection, exclusions: handle, showsCursor: false) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Precancelled capture returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.captures.isEmpty)
        let fresh = try await service.prepareExclusions(windows: [])
        _ = try await service.capture(selection: selection, exclusions: fresh, showsCursor: false)
        XCTAssertEqual(fixture.captures.count, 1)
    }

    @MainActor
    func testNativeDescriptorMatchingRequiresExactIDAndProcess() throws {
        XCTAssertEqual(try RegionExclusionMatching.indices(requestedIDs: [12], windows: [(id: 12, processID: 101)], processID: 101), [0])
        XCTAssertEqual(try RegionExclusionMatching.indices(requestedIDs: [12, 99],
                                                          windows: [(id: 99, processID: 101), (id: 12, processID: 101)],
                                                          processID: 101), [1, 0])
        let invalidLists: [[(id: UInt32, processID: Int32?)]] = [[], [(12, 102)], [(12, nil)], [(12, 101), (12, 101)]]
        for descriptors in invalidLists {
            XCTAssertThrowsError(try RegionExclusionMatching.indices(requestedIDs: [12], windows: descriptors, processID: 101)) {
                XCTAssertEqual($0 as? RegionCaptureError, .missingExcludedWindow(12))
            }
        }
        for ids in [[0], [-1], [12, 12], [Int(UInt32.max) + 1]] {
            XCTAssertThrowsError(try RegionExclusionMatching.indices(requestedIDs: ids, windows: [], processID: 101)) {
                XCTAssertEqual($0 as? RegionCaptureError, .invalidExclusions)
            }
        }
    }

    private enum TestError: Error, Equatable { case injected }

    private func screen(id: String = "A", runtimeID: UInt32 = 1, x: Double = -100, scale: Double = 2) -> RegionDisplay {
        RegionDisplay(id: id, runtimeID: runtimeID, frame: RegionRect(x: x, y: 0, width: 100, height: 100),
                      scale: scale, rotation: 0, backingWidth: 200, backingHeight: 200)
    }

    private func raster(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    private final class Fixture {
        struct Call {
            let displayID: String
            let excludedCount: Int
            let source: CGRect
            let width: Int
            let height: Int
            let cursor: Bool
            let audio: Bool
        }
        var displays = [RegionDisplay(id: "A", runtimeID: 1, frame: RegionRect(x: -100, y: 0, width: 100, height: 100),
                                      scale: 2, rotation: 0, backingWidth: 200, backingHeight: 200)]
        var authorized = true
        var requestResult = false
        var grantOnRequest = false
        var requests = 0
        var snapshots = 0
        var preparations = 0
        var captures: [Call] = []
        var snapshotError: Error?
        var snapshotOverride: (() async throws -> RegionCaptureSnapshot)?
        var prepareError: Error?
        var validationError: Error?
        var prepareOverride: (() async throws -> RegionExclusionLease)?
        var captureOverride: ((String, SCStreamConfiguration) async throws -> CGImage)?

        var dependencies: RegionCaptureDependencies {
            RegionCaptureDependencies(preflight: { [self] in authorized }, request: { [self] in
                requests += 1
                if grantOnRequest { authorized = true }
                return requestResult
            }, snapshot: { [self] in
                snapshots += 1
                if let snapshotOverride { return try await snapshotOverride() }
                if let snapshotError { throw snapshotError }
                return RegionCaptureSnapshot(displays: displays, capture: { [self] id, excluded, configuration in
                    captures.append(Call(displayID: id, excludedCount: excluded.count, source: configuration.sourceRect,
                                         width: configuration.width, height: configuration.height,
                                         cursor: configuration.showsCursor, audio: configuration.capturesAudio))
                    if let captureOverride { return try await captureOverride(id, configuration) }
                    let context = try XCTUnwrap(CGContext(data: nil, width: configuration.width, height: configuration.height,
                                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    return try XCTUnwrap(context.makeImage())
                })
            }, prepare: { [self] windows in
                preparations += 1
                XCTAssertTrue(windows.isEmpty, "These tests do not fabricate native windows")
                if let prepareError { throw prepareError }
                if let prepareOverride { return try await prepareOverride() }
                return RegionExclusionLease(excludedWindows: [], validate: { [self] in
                    if let validationError { throw validationError }
                })
            })
        }

        func selection() throws -> RegionSelection {
            try RegionGeometry.select(drag: RegionRect(x: -90, y: 70, width: 20, height: 10), displays: displays)
        }
    }

    @MainActor
    private final class Gate<Value> {
        private var continuation: CheckedContinuation<Value, Error>?
        private var started = false
        private var earlyResult: Result<Value, Error>?
        private let startedExpectation = XCTestExpectation(description: "Controlled dependency entered")
        func run() async throws -> Value {
            precondition(!started, "Each controlled gate has one invocation")
            started = true
            startedExpectation.fulfill()
            if let earlyResult { return try earlyResult.get() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }
        func waitUntilStarted() async {
            if started { return }
            // The timeout is a failure bound only; gate entry, never elapsed time, orders the test.
            let result = await XCTWaiter.fulfillment(of: [startedExpectation], timeout: 5)
            XCTAssertEqual(result, .completed)
        }
        func finish(_ result: Result<Value, Error>) {
            earlyResult = result
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }
}
