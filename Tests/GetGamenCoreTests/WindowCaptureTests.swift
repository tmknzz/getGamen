import CoreGraphics
import Foundation
import ScreenCaptureKit
import XCTest
@testable import GetGamenCore

final class WindowCaptureTests: XCTestCase {
    func testCapturableWindowPredicate() {
        XCTAssertFalse(DirectWindowPicker.isCapturable(layer: 1, width: 100, height: 100, ownerPID: 2, ownPID: 1))
        XCTAssertFalse(DirectWindowPicker.isCapturable(layer: 0, width: 1, height: 100, ownerPID: 2, ownPID: 1))
        XCTAssertFalse(DirectWindowPicker.isCapturable(layer: 0, width: 100, height: 1, ownerPID: 2, ownPID: 1))
        XCTAssertFalse(DirectWindowPicker.isCapturable(layer: 0, width: 100, height: 100, ownerPID: 1, ownPID: 1))
        XCTAssertTrue(DirectWindowPicker.isCapturable(layer: 0, width: 100, height: 100, ownerPID: 2, ownPID: 1))
        XCTAssertTrue(DirectWindowPicker.isCapturable(layer: 0, width: 100, height: 100, ownerPID: nil, ownPID: 1))
    }

    @MainActor
    func testWindowConfirmationControlsAndShortcutsWaitForSelection() throws {
        let view = DirectWindowView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        var confirmations: [Bool] = []
        var selections = 0
        view.clicked = { selections += 1 }
        view.confirm = { confirmations.append($0) }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        view.keyDown(with: enter)
        XCTAssertTrue(confirmations.isEmpty)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        XCTAssertEqual(selections, 1)
        XCTAssertTrue(confirmations.isEmpty)
        view.highlight = CGRect(x: 100, y: 100, width: 400, height: 300)
        view.showControls(size: PixelSize(width: 800, height: 600))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.dimensions.stringValue, "800 × 600 px")
        XCTAssertEqual(view.camera.frame.midX, 300)
        XCTAssertEqual(view.camera.frame.union(view.dimensions.frame).midY, 250)
        XCTAssertLessThan(view.dimensions.frame.maxY, view.camera.frame.minY)
        view.camera.performClick(nil)
        view.keyDown(with: enter)
        let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8))
        XCTAssertTrue(view.performKeyEquivalent(with: copy))
        XCTAssertEqual(confirmations, [false, false, true])
        view.mouseDown(with: click)
        XCTAssertEqual(selections, 2)
        XCTAssertEqual(confirmations.count, 3)
    }

    func testDirectSelectionUsesFrontmostWindowAndFlipsGlobalCoordinates() {
        let ordered: [(CGWindowID, CGRect)] = [(1, CGRect(x: 0, y: 100, width: 200, height: 100)),
                                              (2, CGRect(x: 0, y: 0, width: 400, height: 400)),
                                              (3, CGRect(x: -500, y: -200, width: 200, height: 200))]
        XCTAssertEqual(WindowHitTesting.window(at: CGPoint(x: 50, y: 850), primaryTop: 1000, ordered: ordered), 1)
        XCTAssertEqual(WindowHitTesting.window(at: CGPoint(x: 300, y: 850), primaryTop: 1000, ordered: ordered), 2)
        XCTAssertEqual(WindowHitTesting.window(at: CGPoint(x: -450, y: 1100), primaryTop: 1000, ordered: ordered), 3)
        XCTAssertNil(WindowHitTesting.window(at: CGPoint(x: 900, y: 100), primaryTop: 1000, ordered: ordered))
    }

    func testGeometryAndConfigurationUseSelectedWindowScale() throws {
        XCTAssertEqual(try WindowCaptureGeometry.pixelSize(contentRect: CGRect(x: -500, y: -50, width: 120, height: 80),
                                                          pointPixelScale: 1), PixelSize(width: 120, height: 80))
        XCTAssertEqual(try WindowCaptureGeometry.pixelSize(contentRect: CGRect(x: 0, y: 0, width: 120.25, height: 80.1),
                                                          pointPixelScale: 2), PixelSize(width: 241, height: 161))
        for cursor in [false, true] {
            let configuration = try WindowCaptureGeometry.configuration(contentRect: CGRect(x: 0, y: 0, width: 128, height: 96),
                                                                        pointPixelScale: 2, showsCursor: cursor)
            XCTAssertEqual(configuration.width, 256)
            XCTAssertEqual(configuration.height, 192)
            XCTAssertEqual(configuration.showsCursor, cursor)
            XCTAssertTrue(configuration.ignoreShadowsSingleWindow)
            XCTAssertFalse(configuration.capturesAudio)
        }
    }

    func testInvalidGeometryAndIntegerOverflowRejectWithoutConversionTrap() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        for scale in [0.0, -1, .nan, .infinity, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try WindowCaptureGeometry.pixelSize(contentRect: rect, pointPixelScale: scale))
        }
        let invalid = [CGRect(x: 0, y: 0, width: 0, height: 1),
                       CGRect(x: 0, y: 0, width: -1, height: 1),
                       CGRect(x: 0, y: 0, width: 1, height: -1),
                       CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                       CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1),
                       CGRect(x: 0, y: 0, width: CGFloat(Double(Int.max)), height: 1),
                       CGRect(x: 0, y: 0, width: 4_000_000_000, height: 4_000_000_000),
                       CGRect(x: 0, y: 0, width: 2_000_000_000, height: 2_000_000_000)]
        for invalidRect in invalid {
            XCTAssertThrowsError(try WindowCaptureGeometry.pixelSize(contentRect: invalidRect, pointPixelScale: 1))
        }
    }

    @MainActor
    func testSelectionOwnsSessionThroughCaptureAndRejectsDuplicateOrUsedSelection() async throws {
        let picker = FakePicker()
        let service = WindowCaptureService(dependencies: picker.dependencies)
        var confirmations = 0
        service.didConfirmCapture = { confirmations += 1 }
        let gate = CaptureGate()
        let pending = Task { try await service.selectWindow(excludingWindowIDs: [12, 34]) }
        await picker.waitForPresentation(1)
        XCTAssertEqual(picker.exclusions[0], [12, 34])
        do { _ = try await service.selectWindow(); XCTFail("Second selection must be busy") }
        catch { XCTAssertEqual(error as? WindowCaptureService.CaptureError, .busy) }
        var copyTarget = gate.target
        copyTarget.copiesToClipboard = true
        picker.emit(.selected(copyTarget), index: 0)
        XCTAssertEqual(confirmations, 1, "Feedback precedes selection continuation and image acquisition")
        let selection = try await pending.value
        XCTAssertTrue(selection.copiesToClipboard)
        picker.emit(.selected(gate.target), index: 0)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(picker.releases, [])
        do { _ = try await service.selectWindow(); XCTFail("Selected session remains busy") }
        catch { XCTAssertEqual(error as? WindowCaptureService.CaptureError, .busy) }
        let capture = Task { try await service.capture(selection, showsCursor: false) }
        await gate.waitForCapture()
        do { _ = try await service.capture(selection, showsCursor: false); XCTFail("Concurrent capture reused token") }
        catch { XCTAssertEqual(error as? WindowCaptureService.CaptureError, .invalidSelection) }
        XCTAssertEqual(gate.configuration?.width, 128)
        XCTAssertEqual(gate.configuration?.height, 96)
        XCTAssertEqual(gate.configuration?.showsCursor, false)
        XCTAssertEqual(gate.configuration?.ignoreShadowsSingleWindow, true)
        gate.finish(.success(try image()))
        let result = try await capture.value
        XCTAssertEqual(confirmations, 1, "Acquisition must not repeat confirmation feedback")
        XCTAssertEqual(result.width, 128)
        XCTAssertEqual(picker.releases, [0])
        do { _ = try await service.capture(selection, showsCursor: true); XCTFail("Selection must be one-shot") }
        catch { XCTAssertEqual(error as? WindowCaptureService.CaptureError, .invalidSelection) }
        service.cancel()
        XCTAssertEqual(picker.releases, [0])
    }

    @MainActor
    func testCancelledSameOwnerSelectionCannotConsumeSuccessor() async throws {
        let picker = FakePicker()
        let service = WindowCaptureService(dependencies: picker.dependencies)
        let first = try await select(service, picker: picker, target: immediateTarget())
        service.cancel()
        let second = try await select(service, picker: picker, target: immediateTarget())
        do { _ = try await service.capture(first, showsCursor: false); XCTFail("Old token accepted") }
        catch { XCTAssertEqual(error as? WindowCaptureService.CaptureError, .invalidSelection) }
        XCTAssertEqual(picker.releases, [0])
        _ = try await service.capture(second, showsCursor: false)
        XCTAssertEqual(picker.releases, [0, 1])
    }

    @MainActor
    func testForeignSelectionDoesNotCancelItsOwner() async throws {
        let picker = FakePicker()
        let owner = WindowCaptureService(dependencies: picker.dependencies)
        let foreign = WindowCaptureService(dependencies: FakePicker().dependencies)
        let selection = try await select(owner, picker: picker, target: immediateTarget())
        do { _ = try await foreign.capture(selection, showsCursor: false); XCTFail("Foreign token accepted") }
        catch { XCTAssertEqual(error as? WindowCaptureService.CaptureError, .invalidSelection) }
        XCTAssertEqual(picker.releases, [])
        _ = try await owner.capture(selection, showsCursor: true)
        XCTAssertEqual(picker.releases, [0])
    }

    @MainActor
    func testCancellationAndOldObserverCannotConsumeNewContinuation() async throws {
        let picker = FakePicker()
        let service = WindowCaptureService(dependencies: picker.dependencies)
        let first = Task { try await service.selectWindow() }
        await picker.waitForPresentation(1)
        service.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let second = Task { try await service.selectWindow() }
        await picker.waitForPresentation(2)
        picker.emit(.selected(try immediateTarget()), index: 0)
        picker.emit(.cancelled, index: 0)
        XCTAssertEqual(picker.releases, [0])
        picker.emit(.selected(try immediateTarget()), index: 1)
        let selection = try await second.value
        _ = try await service.capture(selection, showsCursor: false)
        XCTAssertEqual(picker.releases, [0, 1])
    }

    @MainActor
    func testTaskCancellationBeforeAndDuringSelection() async throws {
        let picker = FakePicker()
        let service = WindowCaptureService(dependencies: picker.dependencies)
        let before = Task { try await service.selectWindow() }
        before.cancel()
        do { _ = try await before.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(picker.callbacks.isEmpty)
        let during = Task { try await service.selectWindow() }
        await picker.waitForPresentation(1)
        during.cancel()
        do { _ = try await during.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(picker.releases, [0])
    }

    @MainActor
    func testLateCaptureSuccessAndFailureAfterCancelDoNotCleanUpNewSession() async throws {
        for fails in [false, true] {
            let picker = FakePicker()
            let service = WindowCaptureService(dependencies: picker.dependencies)
            let gate = CaptureGate()
            let selected = try await select(service, picker: picker, target: gate.target)
            let capture = Task { try await service.capture(selected, showsCursor: true) }
            await gate.waitForCapture()
            service.cancel()
            let newSelection = Task { try await service.selectWindow() }
            await picker.waitForPresentation(2)
            if fails { gate.finish(.failure(NSError(domain: "LateNative", code: 99))) }
            else { gate.finish(.success(try image())) }
            do { _ = try await capture.value; XCTFail("Late result published") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(picker.releases, [0])
            picker.emit(.cancelled, index: 1)
            do { _ = try await newSelection.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(picker.releases, [0, 1])
        }
    }

    @MainActor
    func testUnderlyingPickerAndCaptureErrorsPreserved() async throws {
        let picker = FakePicker()
        let service = WindowCaptureService(dependencies: picker.dependencies)
        let expected = NSError(domain: "InjectedNative", code: -3815, userInfo: [NSLocalizedDescriptionKey: "No source"])
        let choosing = Task { try await service.selectWindow() }
        await picker.waitForPresentation(1)
        picker.emit(.failed(expected), index: 0)
        do { _ = try await choosing.value; XCTFail("Expected picker error") }
        catch { XCTAssertEqual((error as NSError).domain, expected.domain); XCTAssertEqual((error as NSError).code, expected.code) }
        let target = WindowCaptureTarget(geometry: { (CGRect(x: 0, y: 0, width: 128, height: 96), 1) }, capture: { _ in throw expected })
        let selection = try await select(service, picker: picker, target: target)
        do { _ = try await service.capture(selection, showsCursor: true); XCTFail("Expected capture error") }
        catch { XCTAssertEqual((error as NSError).domain, expected.domain); XCTAssertEqual((error as NSError).code, expected.code) }
        XCTAssertEqual(picker.releases, [0, 1])
    }

    @MainActor
    func testOffMainFinalOwnerReleaseCleansSelectedNativeSessionExactlyOnce() async throws {
        let picker = FakePicker()
        var service: WindowCaptureService? = WindowCaptureService(dependencies: picker.dependencies)
        let observed = { [weak service] in service }
        _ = try await select(XCTUnwrap(service), picker: picker, target: immediateTarget())
        let box = ReleaseBox(try XCTUnwrap(service)); service = nil
        await Task.detached { box.value = nil }.value
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNil(observed())
        XCTAssertEqual(picker.releases, [0])
    }

    // Ownership is transferred once to a detached task and is never read concurrently.
    private final class ReleaseBox: @unchecked Sendable {
        var value: WindowCaptureService?
        init(_ value: WindowCaptureService) { self.value = value }
    }

    @MainActor
    func testSynchronousPresentationFailureAndSelectedServiceDestructionReleaseOnce() async throws {
        var releases = 0
        let synchronous = WindowCaptureService(dependencies: WindowCaptureDependencies(begin: { _, receive in
            receive(.cancelled)
            return { releases += 1 }
        }))
        do { _ = try await synchronous.selectWindow(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(releases, 1)
        let readyTarget = try immediateTarget()
        let selectedSynchronously = WindowCaptureService(dependencies: WindowCaptureDependencies(begin: { _, receive in
            receive(.selected(readyTarget))
            return { releases += 1 }
        }))
        let readySelection = try await selectedSynchronously.selectWindow()
        XCTAssertEqual(releases, 1)
        _ = try await selectedSynchronously.capture(readySelection, showsCursor: false)
        XCTAssertEqual(releases, 2)
        let picker = FakePicker()
        var service: WindowCaptureService? = WindowCaptureService(dependencies: picker.dependencies)
        let observeService = { [weak service] in service }
        _ = try await select(service!, picker: picker, target: immediateTarget())
        service = nil
        XCTAssertNil(observeService())
        XCTAssertEqual(picker.releases, [0])
    }

    @MainActor
    func testCaptureTaskCancellationSuppressesReturnedImage() async throws {
        let picker = FakePicker()
        let service = WindowCaptureService(dependencies: picker.dependencies)
        let gate = CaptureGate()
        let selection = try await select(service, picker: picker, target: gate.target)
        let pending = Task { try await service.capture(selection, showsCursor: false) }
        await gate.waitForCapture()
        pending.cancel()
        gate.finish(.success(try image()))
        do { _ = try await pending.value; XCTFail("Cancelled task published image") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(picker.releases, [0])
    }

    @MainActor
    func testInvalidCaptureGeometryAndCancelledSelectionNeverCallEncoder() async throws {
        let picker = FakePicker()
        let service = WindowCaptureService(dependencies: picker.dependencies)
        var calls = 0
        let invalid = WindowCaptureTarget(geometry: { (.zero, 1) }, capture: { _ in calls += 1; return try self.image() })
        let selection = try await select(service, picker: picker, target: invalid)
        do { _ = try await service.capture(selection, showsCursor: true); XCTFail("Expected invalid geometry") }
        catch { XCTAssertEqual(error as? WindowCaptureService.CaptureError, .invalidGeometry) }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(picker.releases, [0])
        let cancelled = try await select(service, picker: picker, target: immediateTarget())
        service.cancel()
        do { _ = try await service.capture(cancelled, showsCursor: true); XCTFail("Cancelled token accepted") }
        catch { XCTAssertEqual(error as? WindowCaptureService.CaptureError, .invalidSelection) }
        XCTAssertEqual(picker.releases, [0, 1])
    }

    @MainActor
    private func select(_ service: WindowCaptureService, picker: FakePicker,
                        target: WindowCaptureTarget) async throws -> WindowCaptureService.Selection {
        let count = picker.callbacks.count + 1
        let pending = Task { try await service.selectWindow() }
        await picker.waitForPresentation(count)
        picker.emit(.selected(target), index: count - 1)
        return try await pending.value
    }

    @MainActor
    private func immediateTarget() throws -> WindowCaptureTarget {
        let result = try image()
        return WindowCaptureTarget(geometry: { (CGRect(x: 0, y: 0, width: 128, height: 96), 1) }, capture: { _ in result })
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class FakePicker {
    var callbacks: [@MainActor (WindowPickerEvent) -> Void] = []
    var exclusions: [[Int]] = []
    var releases: [Int] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []

    var dependencies: WindowCaptureDependencies {
        WindowCaptureDependencies { [self] exclusions, receive in
            let id = callbacks.count
            callbacks.append(receive)
            self.exclusions.append(exclusions)
            let ready = waiting.filter { $0.0 <= callbacks.count }
            waiting.removeAll { $0.0 <= callbacks.count }
            for item in ready { item.1.resume() }
            return { [self] in releases.append(id) }
        }
    }

    func emit(_ event: WindowPickerEvent, index: Int) { callbacks[index](event) }
    func waitForPresentation(_ count: Int) async {
        if callbacks.count >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }
}

@MainActor
private final class CaptureGate {
    var configuration: SCStreamConfiguration?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    var target: WindowCaptureTarget {
        WindowCaptureTarget(geometry: { (CGRect(x: 0, y: 0, width: 128, height: 96), 1) }, capture: { [self] configuration in
            self.configuration = configuration
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let waiting = startedWaiters
                startedWaiters.removeAll()
                for item in waiting { item.resume() }
            }
        })
    }
    func waitForCapture() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func finish(_ result: Result<CGImage, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
