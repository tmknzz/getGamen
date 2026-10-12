import AppKit
import ScreenCaptureKit
import XCTest
@testable import GetGamenCore

/// Presentation and transport are injected; no test claims native selection/capture verification.
final class RegionSelectionControllerTests: XCTestCase {
    @MainActor
    func testCopyIntentSurvivesPreparingSelection() async throws {
        let f = Fixture()
        let controller = f.controller()
        var confirmations = 0
        controller.didConfirmCapture = { confirmations += 1 }
        let task = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { task.cancel() }
        let group = try await f.waitPresented(0)
        group.send(.began(CGPoint(x: -90, y: 70)))
        group.send(.changed(CGPoint(x: -70, y: 80)))
        group.send(.copyRequested)
        XCTAssertEqual(confirmations, 0)
        group.send(.ended(CGPoint(x: -70, y: 80)))
        XCTAssertEqual(confirmations, 1, "Feedback must be synchronous, before asynchronous preparation")
        let lease = try await task.value
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(lease.copiesToClipboard)
        lease.cancel()
    }

    @MainActor
    func testAllDragDirectionsNegativeOriginAndZeroArea() async throws {
        let endpoints: [(CGPoint, CGPoint)] = [
            (CGPoint(x: -90, y: 70), CGPoint(x: -70, y: 80)),
            (CGPoint(x: -70, y: 80), CGPoint(x: -90, y: 70)),
            (CGPoint(x: -90, y: 80), CGPoint(x: -70, y: 70)),
            (CGPoint(x: -70, y: 70), CGPoint(x: -90, y: 80))]
        for (start, end) in endpoints {
            let f = Fixture()
            let controller = f.controller()
            let task = Task { try await controller.select(cancelShortcut: self.binding) }
            defer { task.cancel() }
            let group = try await f.waitPresented(0)
            group.send(.began(start)); group.send(.ended(start))
            XCTAssertEqual(f.prepareCount, 0)
            XCTAssertEqual(group.closes, 0)
            group.send(.began(start)); group.send(.changed(end)); group.send(.ended(end))
            let lease = try await task.value
            XCTAssertEqual(lease.pixelSize, PixelSize(width: 40, height: 20))
            XCTAssertEqual(group.sizes.compactMap { $0 }.last, PixelSize(width: 40, height: 20))
            XCTAssertEqual(f.prepareCount, 1)
            XCTAssertEqual(group.closes, 0)
            lease.cancel()
            XCTAssertEqual(group.closes, 1)
        }
    }

    @MainActor
    func testMixedScaleCrossDisplaySizeAndDuplicateMouseUp() async throws {
        let f = Fixture()
        f.displays = [screen("A", x: 0, scale: 1), screen("B", runtime: 2, x: 100, scale: 2)]
        let controller = f.controller()
        let task = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { task.cancel() }
        let group = try await f.waitPresented(0)
        group.send(.began(CGPoint(x: 90, y: 20)))
        group.send(.changed(CGPoint(x: 110, y: 30)))
        group.send(.ended(CGPoint(x: 110, y: 30)))
        group.send(.ended(CGPoint(x: 120, y: 40)))
        let lease = try await task.value
        XCTAssertEqual(lease.pixelSize, PixelSize(width: 40, height: 20))
        XCTAssertEqual(lease.selection.displays.map(\.id), ["A", "B"])
        XCTAssertEqual(f.prepareCount, 1)
        _ = try await lease.capture(showsCursor: false)
        XCTAssertEqual(group.closes, 1)
        do { _ = try await lease.capture(showsCursor: false); XCTFail("Lease reused") }
        catch { XCTAssertEqual(error as? RegionSelectionError, .staleRequest) }
    }

    @MainActor
    func testDeniedPermissionAndInvalidBindingNeverPresent() async throws {
        let f = Fixture()
        f.authorized = false
        let controller = f.controller()
        do { _ = try await controller.select(cancelShortcut: binding); XCTFail("Permission ignored") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .permissionRequired) }
        XCTAssertTrue(f.groups.isEmpty)
        XCTAssertEqual(f.requests, 1)
        f.authorized = true
        do { _ = try await controller.select(cancelShortcut: HotKeyShortcut(keyCode: 128, modifiers: 0)); XCTFail("Invalid binding accepted") }
        catch { XCTAssertEqual(error as? RegionSelectionError, .invalidShortcut) }
        XCTAssertTrue(f.groups.isEmpty)
    }

    @MainActor
    func testSynchronousPresentationCancelAndCompletedDragAreBuffered() async throws {
        for cancelled in [true, false] {
            let f = Fixture()
            f.synchronousEvents = cancelled ? [.cancelled] : [.began(CGPoint(x: -90, y: 70)), .ended(CGPoint(x: -70, y: 80))]
            let controller = f.controller()
            do {
                let lease = try await controller.select(cancelShortcut: binding)
                XCTAssertFalse(cancelled)
                XCTAssertEqual(lease.pixelSize, PixelSize(width: 40, height: 20))
                XCTAssertTrue(f.prepareSawReturnedPresentation)
                lease.cancel()
            } catch { XCTAssertTrue(cancelled); XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(f.groups.count, 1)
            XCTAssertEqual(f.groups[0].closes, 1)
            XCTAssertEqual(f.prepareCount, cancelled ? 0 : 1)
            XCTAssertFalse(f.groups[0].updatedBeforeReturn)
        }
    }

    @MainActor
    func testPrepareCancellationHidesImmediatelyButClosesOnlyAfterUnwind() async throws {
        let f = Fixture()
        let gate = Gate<RegionExclusionLease>()
        defer { gate.finish(.failure(Injected.failed)) }
        f.prepareBody = { try await gate.run() }
        let controller = f.controller()
        let task = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { task.cancel() }
        let group = try await f.waitPresented(0)
        drag(group)
        await gate.waitStarted()
        XCTAssertEqual(group.hides, 0)
        XCTAssertEqual(group.closes, 0)
        controller.cancel()
        XCTAssertGreaterThan(group.hides, 0)
        XCTAssertEqual(group.closes, 0)
        do { _ = try await task.value; XCTFail("Canceled preparation returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await controller.select(cancelShortcut: binding); XCTFail("Controller not busy during unwind") }
        catch { XCTAssertEqual(error as? RegionSelectionError, .busy) }
        gate.finish(.success(RegionExclusionLease(excludedWindows: [], validate: {})))
        await group.waitClosed()
        XCTAssertEqual(group.closes, 1)
        f.prepareBody = nil
        let nextTask = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { nextTask.cancel() }
        let next = try await f.waitPresented(1)
        group.send(.cancelled)
        XCTAssertEqual(next.closes, 0)
        next.send(.cancelled)
        do { _ = try await nextTask.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testGlobalTranslationDuringPrepareRejectsEvenIfLocalPlanWouldMatch() async throws {
        let f = Fixture()
        let gate = Gate<RegionExclusionLease>()
        defer { gate.finish(.failure(Injected.failed)) }
        f.prepareBody = { try await gate.run() }
        let controller = f.controller()
        let task = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { task.cancel() }
        let group = try await f.waitPresented(0)
        drag(group)
        await gate.waitStarted()
        f.displays = [screen("A", x: 300, scale: 2)]
        gate.finish(.success(RegionExclusionLease(excludedWindows: [], validate: {})))
        do { _ = try await task.value; XCTFail("Moved visible selection accepted") }
        catch { XCTAssertEqual(error as? RegionGeometryError, .topologyChanged) }
        XCTAssertEqual(group.closes, 1)
    }

    @MainActor
    func testTopologyNotificationAndSnapshotErrorFinishOnce() async throws {
        let f = Fixture()
        let controller = f.controller()
        let task = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { task.cancel() }
        let group = try await f.waitPresented(0)
        group.send(.topologyChanged); group.send(.topologyChanged)
        do { _ = try await task.value; XCTFail("Topology ignored") }
        catch { XCTAssertEqual(error as? RegionGeometryError, .topologyChanged) }
        XCTAssertEqual(group.closes, 1)
        f.snapshotError = Injected.failed
        do { _ = try await controller.select(cancelShortcut: binding); XCTFail("Snapshot error swallowed") }
        catch { XCTAssertEqual(error as? Injected, .failed) }
        XCTAssertEqual(f.groups.count, 1)
    }

    @MainActor
    func testBusyCaptureServiceIsNeverCancelledByControllerCleanup() async throws {
        let f = Fixture()
        let service = f.service()
        let foreign = try await service.prepareExclusions(windows: [])
        let controller = RegionSelectionController(captureService: service, presentation: f.presentation)
        let task = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { task.cancel() }
        let group = try await f.waitPresented(0)
        drag(group)
        do { _ = try await task.value; XCTFail("Busy service accepted") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .busy) }
        controller.cancel()
        let selection = try RegionGeometry.select(drag: RegionRect(x: -90, y: 70, width: 20, height: 10), displays: f.displays)
        _ = try await service.capture(selection: selection, exclusions: foreign, showsCursor: false)
        XCTAssertEqual(group.closes, 1)
    }

    @MainActor
    func testPreparedCancellationAndDroppedUnusedLeaseReleaseResources() async throws {
        let f = Fixture()
        let controller = f.controller()
        var lease: RegionSelectionController.PreparedRegion? = try await prepared(controller, fixture: f)
        let observe = { [weak lease] in lease }
        lease = nil
        XCTAssertNil(observe())
        XCTAssertEqual(f.groups[0].closes, 1)
        let next = try await prepared(controller, fixture: f)
        next.cancel(); next.cancel()
        XCTAssertEqual(f.groups[1].closes, 1)
        XCTAssertEqual(f.captureCount, 0)
        do { _ = try await next.capture(showsCursor: false); XCTFail("Canceled lease captured") }
        catch { XCTAssertEqual(error as? RegionSelectionError, .staleRequest) }
    }

    @MainActor
    func testDroppingControllerCancelsRetainedLeaseWithoutRetainCycle() async throws {
        let f = Fixture()
        var controller: RegionSelectionController? = f.controller()
        let observe = { [weak controller] in controller }
        let lease = try await prepared(controller!, fixture: f)
        controller = nil
        XCTAssertNil(observe())
        XCTAssertEqual(f.groups[0].closes, 1)
        do { _ = try await lease.capture(showsCursor: false); XCTFail("Orphaned lease captured") }
        catch { XCTAssertEqual(error as? RegionSelectionError, .staleRequest) }
    }

    @MainActor
    func testCaptureCancellationKeepsPanelsUntilLateSuccessOrErrorUnwinds() async throws {
        for failed in [false, true] {
            let f = Fixture()
            let gate = Gate<CGImage>()
            defer { gate.finish(.failure(Injected.failed)) }
            f.captureBody = { _, _ in try await gate.run() }
            let controller = f.controller()
            let lease = try await prepared(controller, fixture: f)
            let group = f.groups[0]
            let capture = Task { try await lease.capture(showsCursor: false) }
            defer { capture.cancel() }
            await gate.waitStarted()
            lease.cancel()
            XCTAssertEqual(group.closes, 0)
            XCTAssertGreaterThan(group.hides, 0)
            do { _ = try await controller.select(cancelShortcut: binding); XCTFail("Pending capture not busy") }
            catch { XCTAssertEqual(error as? RegionSelectionError, .busy) }
            if failed { gate.finish(.failure(Injected.failed)) }
            else { gate.finish(.success(try image(width: 40, height: 20))) }
            do { _ = try await capture.value; XCTFail("Late image published") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(group.closes, 1)
            f.captureBody = nil
            let fresh = try await prepared(controller, fixture: f)
            lease.cancel()
            XCTAssertEqual(f.groups[1].closes, 0)
            fresh.cancel()
        }
    }

    @MainActor
    func testTaskCancellationAtSynchronousSelectionCompletionCannotPublishLease() async throws {
        let f = Fixture()
        f.synchronousEvents = [.began(CGPoint(x: -90, y: 70)), .ended(CGPoint(x: -70, y: 80))]
        let controller = f.controller()
        let gate = Gate<RegionExclusionLease>()
        defer { gate.finish(.failure(Injected.failed)) }
        f.prepareBody = { try await gate.run() }
        let task = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { task.cancel() }
        await gate.waitStarted()
        task.cancel()
        gate.finish(.success(RegionExclusionLease(excludedWindows: [], validate: {})))
        do { _ = try await task.value; XCTFail("Canceled selection returned lease") }
        catch { XCTAssertTrue(error is CancellationError) }
        await f.groups[0].waitClosed()
        XCTAssertEqual(f.groups[0].closes, 1)
    }

    @MainActor
    func testCallerOwnedAdditionalWindowIsHiddenButNeverClosed() async throws {
        _ = NSApplication.shared
        let window = TrackedWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                   styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let f = Fixture()
        f.expectedWindows = [window]
        let controller = f.controller()
        let task = Task { try await controller.select(cancelShortcut: self.binding, additionalExclusionWindows: [window, window]) }
        defer { task.cancel() }
        let group = try await f.waitPresented(0)
        drag(group)
        let lease = try await task.value
        XCTAssertGreaterThan(window.orderOutCount, 0)
        XCTAssertEqual(window.closeCount, 0)
        lease.cancel()
        XCTAssertEqual(window.closeCount, 0)
        XCTAssertEqual(group.closes, 1)
    }

    @MainActor
    func testCleanupBarrierWaitsThroughCancelledPreparationForAllObservers() async throws {
        let f = Fixture()
        let gate = Gate<RegionExclusionLease>()
        defer { gate.finish(.failure(Injected.failed)) }
        f.prepareBody = { try await gate.run() }
        let controller = f.controller()
        let selection = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { selection.cancel() }
        let group = try await f.waitPresented(0)
        drag(group)
        await gate.waitStarted()
        controller.cancel()
        do { _ = try await selection.value; XCTFail("Expected prompt cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }

        let entered = XCTestExpectation(description: "Both cleanup observers entered")
        entered.expectedFulfillmentCount = 2
        let completed = XCTestExpectation(description: "Both cleanup observers finished")
        completed.expectedFulfillmentCount = 2
        var completionCount = 0
        let first = Task { @MainActor in
            entered.fulfill()
            await controller.waitUntilIdle()
            XCTAssertEqual(group.closes, 1, "Native cleanup precedes every observer return")
            completionCount += 1
            completed.fulfill()
        }
        let second = Task { @MainActor in
            entered.fulfill()
            await controller.waitUntilIdle()
            XCTAssertEqual(group.closes, 1, "Native cleanup precedes every observer return")
            completionCount += 1
            completed.fulfill()
        }
        defer { first.cancel(); second.cancel() }
        let started = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(started, .completed)
        second.cancel()
        XCTAssertEqual(completionCount, 0, "Cancellation must not bypass resource cleanup")
        XCTAssertEqual(group.closes, 0)
        gate.finish(.failure(Injected.failed))
        let finished = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(finished, .completed)
        XCTAssertEqual(completionCount, 2)
        XCTAssertEqual(group.closes, 1)
    }

    @MainActor
    func testCleanupBarrierWaitsForCaptureAndDoesNotConsumeNextLease() async throws {
        let f = Fixture()
        let controller = f.controller()
        let lease = try await prepared(controller, fixture: f)
        let gate = Gate<CGImage>()
        defer { gate.finish(.failure(Injected.failed)) }
        f.captureBody = { _, _ in try await gate.run() }
        let capture = Task { try await lease.capture(showsCursor: false) }
        defer { capture.cancel() }
        await gate.waitStarted()
        lease.cancel()
        let entered = XCTestExpectation(description: "Capture cleanup observer entered")
        let completed = XCTestExpectation(description: "Capture cleanup observer finished")
        var returned = false
        let observer = Task { @MainActor in
            entered.fulfill()
            await controller.waitUntilIdle()
            returned = true
            completed.fulfill()
        }
        defer { observer.cancel() }
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(enteredResult, .completed)
        XCTAssertFalse(returned)
        XCTAssertEqual(f.groups[0].closes, 0)
        gate.finish(.success(try image(width: 40, height: 20)))
        do { _ = try await capture.value; XCTFail("Cancelled capture returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        let completedResult = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completedResult, .completed)
        XCTAssertTrue(returned)
        XCTAssertEqual(f.groups[0].closes, 1)
        f.captureBody = nil
        let next = try await prepared(controller, fixture: f)
        XCTAssertEqual(f.groups[1].closes, 0)
        observer.cancel()
        _ = try await next.capture(showsCursor: false)
        XCTAssertEqual(f.groups[1].closes, 1)
    }

    @MainActor
    func testCleanupBarrierWhenIdleReturnsWithoutStartingNativeWork() async {
        let f = Fixture()
        let controller = f.controller()
        let completed = XCTestExpectation(description: "Idle cleanup observer finished")
        let observer = Task { @MainActor in
            await controller.waitUntilIdle()
            completed.fulfill()
        }
        defer { observer.cancel() }
        let completedResult = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completedResult, .completed)
        XCTAssertTrue(f.groups.isEmpty)
        XCTAssertEqual(f.prepareCount, 0)
        XCTAssertEqual(f.captureCount, 0)
    }

    @MainActor
    func testInitialSelectionWaitsForConfirmation() async throws {
        let f = Fixture()
        let initial = try RegionGeometry.select(drag: RegionRect(x: -90, y: 70, width: 20, height: 10), displays: f.displays)
        let plan = try RegionGeometry.plan(selection: initial, displays: f.displays)
        let controller = f.controller()
        var confirmations = 0
        controller.didConfirmCapture = { confirmations += 1 }
        let task = Task { try await controller.select(cancelShortcut: self.binding, initialSelection: initial) }
        defer { task.cancel() }
        let group = try await f.waitPresented(0)
        XCTAssertEqual(group.presets, [try RegionGeometry.dragRect(for: initial, displays: f.displays)])
        XCTAssertEqual(try XCTUnwrap(group.sizes.last), plan.outputSize)
        XCTAssertEqual(f.prepareCount, 0)
        XCTAssertEqual(confirmations, 0)
        group.send(.ended(CGPoint(x: -70, y: 80)))
        let lease = try await task.value
        XCTAssertEqual(lease.selection, initial)
        XCTAssertEqual(confirmations, 1)
        lease.cancel()
    }

    @MainActor
    func testInitialSelectionWithChangedTopologyNeverPresents() async throws {
        let f = Fixture()
        let initial = try RegionGeometry.select(drag: RegionRect(x: -90, y: 70, width: 20, height: 10), displays: f.displays)
        f.displays = [screen("A", x: -100, scale: 1)]
        let controller = f.controller()
        do {
            let lease = try await controller.select(cancelShortcut: binding, initialSelection: initial)
            lease.cancel()
            XCTFail("Changed topology accepted")
        } catch { XCTAssertEqual(error as? PreviousRegionError, .reselectionRequired(.topologyChanged)) }
        XCTAssertTrue(f.groups.isEmpty)
    }

    private var binding: HotKeyShortcut { HotKeyShortcut(keyCode: 53, modifiers: 0) }
    private enum Injected: Error, Equatable { case failed }
    private func screen(_ id: String, runtime: UInt32 = 1, x: Double, scale: Double) -> RegionDisplay {
        RegionDisplay(id: id, runtimeID: runtime, frame: RegionRect(x: x, y: 0, width: 100, height: 100), scale: scale,
                      rotation: 0, backingWidth: 200, backingHeight: 200)
    }
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    @MainActor private func drag(_ group: Group) {
        group.send(.began(CGPoint(x: -90, y: 70)))
        group.send(.changed(CGPoint(x: -70, y: 80)))
        group.send(.ended(CGPoint(x: -70, y: 80)))
    }
    @MainActor private func prepared(_ controller: RegionSelectionController, fixture: Fixture) async throws -> RegionSelectionController.PreparedRegion {
        let index = fixture.groups.count
        let task = Task { try await controller.select(cancelShortcut: self.binding) }
        defer { task.cancel() }
        let group = try await fixture.waitPresented(index)
        drag(group)
        return try await task.value
    }

    @MainActor private final class Fixture {
        var authorized = true
        var requests = 0
        var prepareCount = 0
        var captureCount = 0
        var prepareSawReturnedPresentation = false
        var snapshotError: Error?
        var displays = [RegionDisplay(id: "A", runtimeID: 1, frame: RegionRect(x: -100, y: 0, width: 100, height: 100),
                                      scale: 2, rotation: 0, backingWidth: 200, backingHeight: 200)]
        var prepareBody: (() async throws -> RegionExclusionLease)?
        var captureBody: ((String, SCStreamConfiguration) async throws -> CGImage)?
        var synchronousEvents: [RegionSelectionEvent] = []
        var expectedWindows: [NSWindow] = []
        var groups: [Group] = []
        private var presentationWaiters: [Int: XCTestExpectation] = [:]
        func service() -> RegionCaptureService {
            RegionCaptureService(dependencies: RegionCaptureDependencies(preflight: { [self] in authorized }, request: { [self] in
                requests += 1; return authorized
            }, snapshot: { [self] in
                if let snapshotError { throw snapshotError }
                return RegionCaptureSnapshot(displays: displays, capture: { [self] id, _, configuration in
                    captureCount += 1
                    if let captureBody { return try await captureBody(id, configuration) }
                    let context = try XCTUnwrap(CGContext(data: nil, width: configuration.width, height: configuration.height,
                                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    return try XCTUnwrap(context.makeImage())
                })
            }, prepare: { [self] windows in
                prepareCount += 1
                prepareSawReturnedPresentation = groups.last?.returned ?? false
                XCTAssertEqual(windows.map(ObjectIdentifier.init), expectedWindows.map(ObjectIdentifier.init),
                               "Only exact supplied windows enter injected descriptor preparation")
                if let prepareBody { return try await prepareBody() }
                return RegionExclusionLease(excludedWindows: [], validate: {})
            }))
        }
        var presentation: RegionSelectionPresentation {
            RegionSelectionPresentation(present: { [self] _, _, receive in
                let group = Group(send: receive)
                let index = groups.count
                groups.append(group)
                for event in synchronousEvents { receive(event) }
                group.returned = true
                presentationWaiters[index]?.fulfill()
                return RegionSelectionPanels(windows: [], update: { rect, size in
                    group.updatedBeforeReturn = group.updatedBeforeReturn || !group.returned
                    group.sizes.append(size)
                }, hide: { group.hides += 1 }, close: {
                    group.closes += 1
                    if group.closes == 1 { group.closed.fulfill() }
                }, preset: { group.presets.append($0) })
            })
        }
        func controller() -> RegionSelectionController { RegionSelectionController(captureService: service(), presentation: presentation) }
        func waitPresented(_ index: Int) async throws -> Group {
            if groups.count <= index {
                let expectation = XCTestExpectation(description: "Presentation \(index) started")
                presentationWaiters[index] = expectation
                let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
                XCTAssertEqual(result, .completed)
            }
            if groups.count > index { return groups[index] }
            throw Injected.failed
        }
    }

    @MainActor private final class Group {
        let send: @MainActor (RegionSelectionEvent) -> Void
        var returned = false
        var updatedBeforeReturn = false
        var sizes: [PixelSize?] = []
        var presets: [RegionRect] = []
        var hides = 0
        var closes = 0
        let closed = XCTestExpectation(description: "Owned panels closed")
        init(send: @escaping @MainActor (RegionSelectionEvent) -> Void) { self.send = send }
        func waitClosed() async {
            if closes > 0 { return }
            let result = await XCTWaiter.fulfillment(of: [closed], timeout: 5)
            XCTAssertEqual(result, .completed)
        }
    }
    @MainActor private final class Gate<Value> {
        private var continuation: CheckedContinuation<Value, Error>?
        private var early: Result<Value, Error>?
        private var started = false
        private let expectation = XCTestExpectation(description: "Dependency started")
        func run() async throws -> Value {
            precondition(!started)
            started = true
            expectation.fulfill()
            if let early { return try early.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func waitStarted() async {
            if started { return }
            let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
            XCTAssertEqual(result, .completed)
        }
        func finish(_ result: Result<Value, Error>) {
            early = result
            let old = continuation
            continuation = nil
            old?.resume(with: result)
        }
    }

    @MainActor private final class TrackedWindow: NSWindow {
        var orderOutCount = 0
        var closeCount = 0
        override func orderOut(_ sender: Any?) { orderOutCount += 1; super.orderOut(sender) }
        override func close() { closeCount += 1; super.close() }
    }
}
