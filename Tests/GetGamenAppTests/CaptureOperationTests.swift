import AppKit
import Foundation
import ScreenCaptureKit
import XCTest
@testable import GetGamen
@testable import GetGamenCore

/// These tests execute the app orchestration and real core ownership paths with injected transport.
/// They do not request permissions, present native selection UI, or capture a real screen.
final class CaptureOperationTests: XCTestCase {
    @MainActor
    func testConfirmedTimerFreezesSoundAndDelayAcrossLaterSettingsChanges() async throws {
        let f = try Fixture(); defer { f.remove() }
        for initial in [0, 3] {
            try f.captureSettings.setTimerSeconds(initial)
            var events: [String] = []
            weak var current: AppRuntime?
            let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
                editorWindows: f.editorWindows, cancelShortcut: f.binding,
                prepare: { _, _, _ in
                    current?.confirmCapture()
                    current?.confirmCapture()
                    try f.captureSettings.setTimerSeconds(initial == 0 ? 3 : 0)
                    current?.updateSelectionTimer(initial == 0 ? 3 : 0)
                    return PreparedCapture(capture: { _ in
                        events.append("capture")
                        return CapturedImage(image: try Self.image(), previousRecordError: nil)
                    }, cancel: {}, waitForCleanup: {})
                }, wait: { seconds, remaining in
                    XCTAssertEqual(seconds, initial)
                    events.append("wait")
                    remaining(0)
                }, didCapture: { _, _ in })
            current = runtime
            runtime.didConfirmImmediately = { events.append("sound") }
            runtime.didFinishCountdown = { events.append("sound") }
            try runtime.startCapture(.window)
            await runtime.waitUntilIdle()
            XCTAssertEqual(events, initial == 0 ? ["sound", "wait", "capture"] : ["wait", "sound", "capture"])
        }
    }

    @MainActor
    func testTimerSoundFollowsZeroBeforeCaptureAndCancellationStaysSilent() async throws {
        let f = try Fixture(); defer { f.remove() }
        for seconds in [0, 3, 5, 12] {
            for cancel in [false, true] {
                try f.captureSettings.setTimerSeconds(seconds)
                var events: [String] = []
                let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
                    editorWindows: f.editorWindows, cancelShortcut: f.binding,
                    prepare: { _, _, _ in
                        PreparedCapture(capture: { _ in
                            events.append("capture")
                            return CapturedImage(image: try Self.image(), previousRecordError: nil)
                        }, cancel: {}, waitForCleanup: {})
                    }, wait: { delay, remaining in
                        XCTAssertEqual(delay, seconds)
                        XCTAssertFalse(events.contains("sound"))
                        if cancel { throw CancellationError() }
                        remaining(0)
                        events.append("zero")
                    }, didCapture: { _, _ in })
                runtime.didFinishCountdown = { events.append("sound") }
                try runtime.startCapture(.window)
                await runtime.waitUntilIdle()
                XCTAssertEqual(events, cancel ? [] : (seconds == 0 ? ["zero", "capture"] : ["zero", "sound", "capture"]))
            }
        }
    }

    @MainActor
    func testAutomaticPreviousPreparationsDoNotRepeatConfirmationFeedback() async throws {
        let f = try NativeFixture(); defer { f.remove() }
        var confirmations = 0
        let adapter = CapturePreparation(windowService: f.window, regionController: f.region,
            previousController: f.previous, didConfirmCapture: { confirmations += 1 })
        // No previous area exists: confirmation is feedback for the action, even if preparation fails.
        for first in [true, false, false] {
            do { _ = try await adapter.prepare(mode: .previous, windows: [], cancelShortcut: nil,
                                               confirmsPreviousCapture: first) }
            catch { }
            XCTAssertEqual(confirmations, 1)
        }
    }

    @MainActor
    func testReviewedPreviousWithoutRecordDoesNotPresentOrConfirm() async throws {
        let f = try NativeFixture(); defer { f.remove() }
        var confirmations = 0
        let adapter = CapturePreparation(windowService: f.window, regionController: f.region,
            previousController: f.previous, didConfirmCapture: { confirmations += 1 })
        do {
            _ = try await adapter.prepare(mode: .previous, windows: [], cancelShortcut: f.settings.binding,
                                          reviewsPrevious: true)
            XCTFail("Missing previous region accepted")
        } catch { XCTAssertEqual(error as? PreviousRegionError, .missingPrevious) }
        XCTAssertEqual(f.presentations, 0); XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(f.captures, 0)
    }

    @MainActor
    func testReviewedPreviousPresentsBeforeConfirmationAndCapturesRememberedRegion() async throws {
        let f = try NativeFixture(); defer { f.remove() }
        let display = RegionDisplay(id: "A", runtimeID: 1, frame: RegionRect(x: -100, y: 0, width: 100, height: 100),
            scale: 2, rotation: 0, backingWidth: 200, backingHeight: 200)
        let selection = try RegionGeometry.select(drag: RegionRect(x: -80, y: 20, width: 30, height: 20), displays: [display])
        let adjusted = try RegionGeometry.select(drag: RegionRect(x: -90, y: 70, width: 20, height: 10), displays: [display])
        XCTAssertNotEqual(adjusted, selection)
        try PreviousRegionRecordStore(fileURL: f.record).remember(selection)
        var confirmations = 0
        let adapter = CapturePreparation(windowService: f.window, regionController: f.region,
            previousController: f.previous, didConfirmCapture: {
                XCTAssertEqual(f.presentations, 1)
                XCTAssertEqual(f.captures, 0)
                confirmations += 1
            })
        // The fake presentation confirms an adjusted drag.
        let prepared = try await adapter.prepare(mode: .previous, windows: [], cancelShortcut: f.settings.binding,
                                                 reviewsPrevious: true)
        defer { prepared.cancel() }
        XCTAssertEqual(f.presentations, 1); XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(f.presets, [try RegionGeometry.dragRect(for: selection, displays: [display])])
        XCTAssertEqual(f.captures, 0)
        let captured = try await prepared.capture(showsCursor: false)
        await prepared.waitForCleanup()
        XCTAssertEqual(captured.selection, adjusted)
        XCTAssertNil(captured.previousRecordError)
        XCTAssertEqual(f.captures, 1); XCTAssertEqual(f.panelCloses, 1)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(try PreviousRegionRecordStore(fileURL: f.record).load(), adjusted)
    }

    @MainActor
    func testCaptureFeedbackFollowsAcquisitionBeforeDeliveryAndSkipsFailures() async throws {
        let f = try Fixture(); defer { f.remove() }
        for mode in [CaptureMode.window, .region, .previous] {
            for fails in [false, true] {
                var steps: [String] = []
                let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
                    editorWindows: f.editorWindows, cancelShortcut: f.binding,
                    prepare: { _, _, _ in
                        steps.append("selection")
                        return PreparedCapture(capture: { _ in
                            steps.append("capture")
                            if fails { throw Injected.failed }
                            return CapturedImage(image: try Self.image(), previousRecordError: nil)
                        }, cancel: {}, waitForCleanup: {})
                    }, wait: { _, _ in steps.append("timer") },
                    didCapture: { _, _ in steps.append("delivery") })
                runtime.didAcquireImage = { steps.append("sound") }
                try runtime.startCapture(mode)
                await runtime.waitUntilIdle()
                XCTAssertEqual(steps, fails ? ["selection", "timer", "capture"]
                    : ["selection", "timer", "capture", "sound", "delivery"])
            }
        }
    }

    @MainActor
    func testRegionOutlineIsPublishedOnlyAfterSuccessfulHandoffAndCleanup() async throws {
        let f = try Fixture(); defer { f.remove() }
        let selection = RegionSelection(schemaVersion: 1, anchorID: "test",
            dragInAnchor: RegionRect(x: 0, y: 0, width: 40, height: 30), displays: [])
        for fails in [false, true] {
            var steps: [String] = []
            let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
                editorWindows: f.editorWindows, cancelShortcut: f.binding,
                prepare: { _, _, _ in
                    PreparedCapture(capture: { _ in
                        CapturedImage(image: try Self.image(), previousRecordError: nil, selection: selection)
                    }, cancel: {}, waitForCleanup: { steps.append("cleanup") })
                }, wait: { _, _ in }, didCapture: { _, _ in
                    steps.append("handoff")
                    if fails { throw CancellationError() }
                })
            runtime.didCompleteRegion = { value in
                XCTAssertEqual(value, selection)
                XCTAssertEqual(runtime.activity, .idle)
                steps.append("outline")
            }
            try runtime.startCapture(.region)
            await runtime.waitUntilIdle()
            XCTAssertEqual(steps, fails ? ["handoff", "cleanup"] : ["handoff", "cleanup", "outline"])
            runtime.didCompleteRegion = nil
        }
    }

    @MainActor
    func testTerminationFreezesCaptureUntilExplicitResume() async throws {
        let f = try Fixture(); defer { f.remove() }
        var calls = 0
        let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
            editorWindows: f.editorWindows, cancelShortcut: f.binding,
            prepare: { _, _, _ in calls += 1; throw CancellationError() },
            wait: { _, _ in }, didCapture: { _, _ in })
        runtime.beginTermination()
        XCTAssertThrowsError(try runtime.startCapture(.region)) {
            XCTAssertEqual($0 as? CaptureOperationError, .terminationInProgress)
        }
        await runtime.waitUntilIdle()
        XCTAssertEqual(calls, 0)
        runtime.endTermination()
        try runtime.startCapture(.region)
        await runtime.waitUntilIdle()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testSnapshotsSelectionBeforeCountdownBusyAndOrderedHandoff() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.captureSettings.setTimerSeconds(4)
        f.captureSettings.setShowsCursor(true)
        f.exportSettings.setFormat(.png8)
        try f.exportSettings.setJPEGQuality(0.4)
        let originalExport = f.exportSettings.snapshot
        let gate = Gate<PreparedCapture>(); defer { gate.fail() }
        var steps: [String] = []
        var seenIntent: CaptureIntent?
        var seenBinding: HotKeyShortcut?
        var cursor: Bool?
        let target = PreparedCapture(capture: {
            cursor = $0; steps.append("capture")
            return CapturedImage(image: try Self.image(), previousRecordError: nil)
        }, cancel: { steps.append("cancel") }, waitForCleanup: { steps.append("cleanup") })
        let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
            editorWindows: f.editorWindows,
            cancelShortcut: f.binding, prepare: { mode, windows, binding in
                XCTAssertEqual(mode, .region); XCTAssertTrue(windows.isEmpty)
                seenBinding = binding; steps.append("prepare")
                return try await gate.run()
            }, wait: { seconds, emit in
                steps.append("countdown"); XCTAssertEqual(seconds, 4); emit(4); emit(0)
            }, didCapture: { result, intent in
                XCTAssertEqual(result.image.width, 40); seenIntent = intent; steps.append("handoff")
            })
        XCTAssertEqual(runtime.activity, .idle)
        let id = try runtime.startCapture(.region)
        try await gate.waitStarted()
        XCTAssertEqual(steps, ["prepare"])
        XCTAssertEqual(runtime.activity, .selecting)
        XCTAssertThrowsError(try runtime.startCapture(.window)) { XCTAssertEqual($0 as? CaptureOperationError, .busy) }
        try f.captureSettings.setTimerSeconds(9); f.captureSettings.setShowsCursor(false)
        f.exportSettings.setFormat(.jpeg); try f.exportSettings.setJPEGQuality(0.8)
        gate.finish(.success(target))
        try await idle(runtime)
        XCTAssertEqual(steps, ["prepare", "countdown", "capture", "handoff", "cleanup"])
        XCTAssertEqual(cursor, true)
        XCTAssertEqual(seenBinding, f.binding)
        let intent = try XCTUnwrap(seenIntent)
        XCTAssertEqual(intent.id, id)
        XCTAssertEqual(intent.mode, .region)
        XCTAssertEqual(intent.capture, CaptureSettingsSnapshot(timerSeconds: 4, showsCursor: true))
        XCTAssertEqual(intent.export, originalExport)
        XCTAssertEqual(runtime.activity, .idle)
        XCTAssertNil(runtime.failureMessage)
    }

    @MainActor
    func testUnsupportedScrollRejectedWithoutAnyDependencyCalls() throws {
        let f = try Fixture(); defer { f.remove() }
        var calls = 0
        let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
            editorWindows: f.editorWindows,
            cancelShortcut: f.binding, prepare: { _, _, _ in calls += 1; throw Injected.failed },
            wait: { _, _ in calls += 1 }, didCapture: { _, _ in calls += 1 })
        XCTAssertThrowsError(try runtime.startCapture(.scroll)) { XCTAssertEqual($0 as? CaptureOperationError, .unsupportedMode(.scroll)) }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(runtime.activity, .idle)
    }

    @MainActor
    func testCountdownCallbackCancellationCancelsAcquiredTargetAndDrains() async throws {
        let f = try Fixture(); defer { f.remove() }
        var captures = 0; var cancels = 0; var cleanups = 0; var handoffs = 0
        var cancelRuntime: (() -> Void)?
        let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
            editorWindows: f.editorWindows,
            cancelShortcut: f.binding, prepare: { _, _, _ in
                PreparedCapture(capture: { _ in captures += 1; throw Injected.failed },
                                cancel: { cancels += 1 }, waitForCleanup: { cleanups += 1 })
            }, wait: { _, emit in emit(2); cancelRuntime?(); emit(0) },
            didCapture: { _, _ in handoffs += 1 })
        cancelRuntime = { [weak runtime] in runtime?.cancelCapture() }
        try runtime.startCapture(.window)
        try await idle(runtime)
        XCTAssertEqual(captures, 0); XCTAssertEqual(handoffs, 0)
        XCTAssertEqual(cancels, 1); XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(runtime.activity, .idle); XCTAssertNil(runtime.failureMessage)
    }

    @MainActor
    func testLatePreparedTargetIsCancelledAndLatePreparationErrorIsSuppressed() async throws {
        for failure in [false, true] {
            let f = try Fixture(); defer { f.remove() }
            let gate = Gate<PreparedCapture>(); defer { gate.fail() }
            var cancelled = 0; var cleaned = 0; var calls = 0
            let target = PreparedCapture(capture: { _ in calls += 1; throw Injected.failed },
                                         cancel: { cancelled += 1 }, waitForCleanup: { cleaned += 1 })
            let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
                editorWindows: f.editorWindows,
                cancelShortcut: f.binding, prepare: { _, _, _ in try await gate.run() },
                wait: { _, _ in calls += 1 }, didCapture: { _, _ in calls += 1 })
            try runtime.startCapture(.region)
            try await gate.waitStarted()
            runtime.cancelCapture(); runtime.cancelCapture()
            XCTAssertEqual(runtime.activity, .cancelling)
            XCTAssertThrowsError(try runtime.startCapture(.previous)) { XCTAssertEqual($0 as? CaptureOperationError, .busy) }
            gate.finish(failure ? .failure(Injected.failed) : .success(target))
            try await idle(runtime)
            XCTAssertEqual(calls, 0); XCTAssertNil(runtime.failureMessage)
            if !failure { XCTAssertEqual(cancelled, 1); XCTAssertEqual(cleaned, 1) }
        }
    }

    @MainActor
    func testLateCaptureSuccessAndErrorCannotHandoffAndCleanupWaitersSeeUnwind() async throws {
        for failure in [false, true] {
            let f = try Fixture(); defer { f.remove() }
            let gate = Gate<CapturedImage>(); defer { gate.fail() }
            var unwound = false; var cleaned = false; var handoffs = 0; var sounds = 0
            let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
                editorWindows: f.editorWindows,
                cancelShortcut: f.binding, prepare: { _, _, _ in
                    PreparedCapture(capture: { _ in
                        defer { unwound = true }
                        return try await gate.run()
                    }, cancel: {}, waitForCleanup: { XCTAssertTrue(unwound); cleaned = true })
                }, wait: { _, emit in emit(0) }, didCapture: { _, _ in handoffs += 1 })
            runtime.didAcquireImage = { sounds += 1 }
            try runtime.startCapture(.window)
            try await gate.waitStarted()
            runtime.cancelCapture()
            let entered = XCTestExpectation(description: "Both idle observers entered")
            entered.expectedFulfillmentCount = 2
            let first = Task { @MainActor in
                entered.fulfill(); await runtime.waitUntilIdle(); XCTAssertTrue(cleaned)
            }
            let second = Task { @MainActor in
                entered.fulfill(); await runtime.waitUntilIdle(); XCTAssertTrue(cleaned)
            }
            try await acknowledge(entered)
            first.cancel()
            XCTAssertEqual(runtime.activity, .cancelling)
            gate.finish(failure ? .failure(Injected.failed) : .success(CapturedImage(image: try Self.image(), previousRecordError: nil)))
            try await complete(first); try await complete(second)
            XCTAssertEqual(handoffs, 0); XCTAssertNil(runtime.failureMessage)
            XCTAssertEqual(sounds, 0)
            XCTAssertEqual(runtime.activity, .idle)
        }
    }

    @MainActor
    func testPreparationAndHandoffErrorsAreVisibleAndDoNotBecomeSuccess() async throws {
        for failsAtPreparation in [true, false] {
            let f = try Fixture(); defer { f.remove() }
            var deliveries = 0; var cleaned = 0
            let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
                editorWindows: f.editorWindows,
                cancelShortcut: f.binding, prepare: { _, _, _ in
                    if failsAtPreparation { throw Injected.failed }
                    return PreparedCapture(capture: { _ in CapturedImage(image: try Self.image(), previousRecordError: nil) },
                                           cancel: {}, waitForCleanup: { cleaned += 1 })
                }, wait: { _, emit in emit(0) }, didCapture: { _, _ in deliveries += 1; throw Injected.failed })
            try runtime.startCapture(.region)
            try await idle(runtime)
            XCTAssertNotNil(runtime.failureMessage)
            XCTAssertEqual(deliveries, failsAtPreparation ? 0 : 1)
            XCTAssertEqual(cleaned, failsAtPreparation ? 0 : 1)
            XCTAssertEqual(runtime.activity, .idle)
        }
    }

    @MainActor
    func testRealRegionCancellationRemainsBusyUntilPanelAndNativeCleanup() async throws {
        for lateFailure in [false, true] {
            let f = try NativeFixture(); defer { f.remove() }
            let gate = Gate<RegionExclusionLease>(); defer { gate.fail() }
            var unwound = false
            f.prepareBody = { defer { unwound = true }; return try await gate.run() }
            var deliveries = 0
            let selectionReturned = XCTestExpectation(description: "Real selection returned before cleanup barrier")
            let adapter = CapturePreparation(windowService: f.window, regionController: f.region,
                previousController: f.previous, beforeRegionCleanup: { selectionReturned.fulfill() })
            let runtime = AppRuntime(captureSettings: f.settings.captureSettings, exportSettings: f.settings.exportSettings,
                editorWindows: f.settings.editorWindows,
                cancelShortcut: f.settings.binding, preparation: adapter,
                didCapture: { _, _ in deliveries += 1 })
            try runtime.startCapture(.region)
            try await gate.waitStarted()
            runtime.cancelCapture()
            try await acknowledge(f.hidden)
            try await acknowledge(selectionReturned)
            XCTAssertEqual(f.panelCloses, 0)
            XCTAssertFalse(unwound)
            XCTAssertEqual(runtime.activity, .cancelling)
            XCTAssertThrowsError(try runtime.startCapture(.window)) { XCTAssertEqual($0 as? CaptureOperationError, .busy) }
            let observerEntered = XCTestExpectation(description: "Runtime cleanup observer entered")
            let observer = Task { @MainActor in
                observerEntered.fulfill()
                await runtime.waitUntilIdle()
                XCTAssertTrue(unwound, "Runtime idle cannot precede native unwind")
                XCTAssertEqual(f.panelCloses, 1, "Runtime idle cannot precede panel cleanup")
            }
            defer { observer.cancel() }
            try await acknowledge(observerEntered)
            gate.finish(lateFailure ? .failure(Injected.failed) : .success(RegionExclusionLease(excludedWindows: [], validate: {})))
            try await complete(observer)
            try await idle(runtime)
            XCTAssertTrue(unwound); XCTAssertEqual(f.panelCloses, 1)
            XCTAssertEqual(f.captures, 0); XCTAssertEqual(deliveries, 0)
            XCTAssertNil(runtime.failureMessage)
        }
    }

    @MainActor
    func testProductionRegionAdapterRemembersAndPreservesSeparateWarning() async throws {
        for rememberFails in [false, true] {
            let f = try NativeFixture(failRemember: rememberFails); defer { f.remove() }
            var delivered: CapturedImage?
            let runtime = AppRuntime(captureSettings: f.settings.captureSettings, exportSettings: f.settings.exportSettings,
                editorWindows: f.settings.editorWindows,
                cancelShortcut: f.settings.binding, preparation: f.adapter, didCapture: { image, _ in delivered = image })
            try runtime.startCapture(.region)
            try await idle(runtime)
            XCTAssertEqual(delivered?.image.width, 40)
            if rememberFails {
                XCTAssertEqual(delivered?.previousRecordError as? Injected, .failed)
                XCTAssertNotNil(runtime.previousRecordWarning)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.record.path))
            } else {
                XCTAssertNil(delivered?.previousRecordError)
                XCTAssertNil(runtime.previousRecordWarning)
                XCTAssertNotNil(try PreviousRegionRecordStore(fileURL: f.record).load())
            }
            XCTAssertNil(runtime.failureMessage)
            XCTAssertEqual(f.captures, 1); XCTAssertEqual(f.panelCloses, 1)
        }
    }

    @MainActor
    func testProductionAdapterForeignRegionBusyReturnsWithoutCancellingOrWaitingOnLease() async throws {
        let f = try NativeFixture(); defer { f.remove() }
        let foreign = try await f.region.select(cancelShortcut: f.settings.binding)
        let operation = Task { try await f.adapter.prepare(mode: .region, windows: [], cancelShortcut: f.settings.binding) }
        let result = try await completedResult(operation)
        do { _ = try result.get(); XCTFail("Foreign busy controller accepted") }
        catch { XCTAssertEqual(error as? RegionSelectionError, .busy) }
        XCTAssertEqual(f.panelCloses, 0)
        let image = try await foreign.capture(showsCursor: false)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(f.panelCloses, 1)
    }

    @MainActor
    func testPreviousControllerBusyAndSharedServiceBusyRespectDifferentOwners() async throws {
        let f = try NativeFixture(); defer { f.remove() }
        let display = RegionDisplay(id: "A", runtimeID: 1, frame: RegionRect(x: -100, y: 0, width: 100, height: 100),
            scale: 2, rotation: 0, backingWidth: 200, backingHeight: 200)
        let selection = try RegionGeometry.select(drag: RegionRect(x: -90, y: 70, width: 20, height: 10), displays: [display])
        try PreviousRegionRecordStore(fileURL: f.record).remember(selection)
        let previousOwner = try await f.previous.preparePrevious()
        defer { previousOwner.cancel() }
        let busy = Task { try await f.adapter.prepare(mode: .previous, windows: [], cancelShortcut: f.settings.binding) }
        let result = try await completedResult(busy)
        do { _ = try result.get(); XCTFail("Foreign previous request accepted") }
        catch { XCTAssertEqual(error as? PreviousRegionError, .busy) }
        let previousImage = try await previousOwner.capture(showsCursor: false)
        XCTAssertEqual(previousImage.image.width, 40)

        let serviceOwner = try await f.service.prepareExclusions(windows: [])
        defer { f.service.cancel() }
        let regionAttempt = Task { try await f.adapter.prepare(mode: .region, windows: [], cancelShortcut: f.settings.binding) }
        let rejected = try await completedResult(regionAttempt)
        do { _ = try rejected.get(); XCTFail("Shared service busy ignored") }
        catch { XCTAssertEqual(error as? RegionCaptureError, .busy) }
        XCTAssertEqual(f.panelCloses, 1, "Adapter must drain its own panels despite underlying service busy")
        let image = try await f.service.capture(selection: selection, exclusions: serviceOwner, showsCursor: false)
        XCTAssertEqual(image.width, 40, "Foreign service lease must remain usable")
    }

    @MainActor
    func testOldCountdownCallbackCannotChangeNextOperation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let second = Gate<PreparedCapture>(); defer { second.fail() }
        var count = 0
        var oldCallback: (@MainActor (Int) -> Void)?
        let runtime = AppRuntime(captureSettings: f.captureSettings, exportSettings: f.exportSettings,
            editorWindows: f.editorWindows,
            cancelShortcut: f.binding, prepare: { _, _, _ in
                count += 1
                if count == 2 { return try await second.run() }
                return PreparedCapture(capture: { _ in CapturedImage(image: try Self.image(), previousRecordError: nil) }, cancel: {}, waitForCleanup: {})
            }, wait: { _, emit in oldCallback = emit; emit(0) }, didCapture: { _, _ in })
        let firstID = try runtime.startCapture(.region)
        try await idle(runtime)
        let secondID = try runtime.startCapture(.window)
        XCTAssertNotEqual(firstID, secondID)
        try await second.waitStarted()
        oldCallback?(9)
        XCTAssertEqual(runtime.activity, .selecting)
        runtime.cancelCapture()
        second.fail()
        try await idle(runtime)
        XCTAssertNil(runtime.failureMessage)
    }

    @MainActor
    func testProductionAdapterPreCancelledIdleControllersAndUnsupportedScrollHaveNoSideEffects() async throws {
        let f = try NativeFixture(); defer { f.remove() }
        for mode in [CaptureMode.region, .previous, .window] {
            let operation = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.adapter.prepare(mode: mode, windows: [], cancelShortcut: f.settings.binding)
            }
            let result = try await completedResult(operation)
            do { _ = try result.get(); XCTFail("Precancel accepted") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        do { _ = try await f.adapter.prepare(mode: .scroll, windows: [], cancelShortcut: f.settings.binding); XCTFail("Scroll accepted") }
        catch { XCTAssertEqual(error as? CaptureOperationError, .unsupportedMode(.scroll)) }
        XCTAssertEqual(f.snapshots, 0); XCTAssertEqual(f.presentations, 0)
        XCTAssertEqual(f.permissionCalls, 0); XCTAssertEqual(f.windowBegins, 0)
        XCTAssertEqual(f.captures, 0)
    }

    @MainActor
    func testPreparedCaptureIsOnceOnlyAndTerminalCancelIsNoOp() async throws {
        var captures = 0; var cancellations = 0
        let prepared = PreparedCapture(capture: { _ in captures += 1; return CapturedImage(image: try Self.image(), previousRecordError: nil) },
                                       cancel: { cancellations += 1 }, waitForCleanup: {})
        _ = try await prepared.capture(showsCursor: false)
        prepared.cancel()
        do { _ = try await prepared.capture(showsCursor: false); XCTFail("Wrapper reused") }
        catch { XCTAssertEqual(error as? CaptureOperationError, .staleRequest) }
        XCTAssertEqual(captures, 1); XCTAssertEqual(cancellations, 0)
        let unused = PreparedCapture(capture: { _ in XCTFail("Cancelled target captured"); throw Injected.failed },
                                     cancel: { cancellations += 1 }, waitForCleanup: {})
        unused.cancel(); unused.cancel()
        do { _ = try await unused.capture(showsCursor: false); XCTFail("Cancelled wrapper consumed") }
        catch { XCTAssertEqual(error as? CaptureOperationError, .staleRequest) }
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testProductionWindowAdapterCaptureAndOldFinishedCancelPreserveNewSelection() async throws {
        let f = try NativeFixture(); defer { f.remove() }
        var cleanups = 0
        var cursors: [Bool] = []
        let window = WindowCaptureService(dependencies: WindowCaptureDependencies(begin: { ids, receive in
            XCTAssertTrue(ids.isEmpty)
            receive(.selected(WindowCaptureTarget(geometry: { (CGRect(x: 0, y: 0, width: 40, height: 20), 1) }, capture: { configuration in
                cursors.append(configuration.showsCursor)
                XCTAssertTrue(configuration.ignoreShadowsSingleWindow)
                XCTAssertEqual(configuration.width, 40); XCTAssertEqual(configuration.height, 20)
                return try Self.image()
            })))
            return { cleanups += 1 }
        }))
        defer { window.cancel() }
        let adapter = CapturePreparation(windowService: window, regionController: f.region, previousController: f.previous)
        let prepared = try await completedResult(Task {
            try await adapter.prepare(mode: .window, windows: [], cancelShortcut: f.settings.binding)
        }).get()
        let captured = try await completedResult(Task { try await prepared.capture(showsCursor: true) }).get()
        XCTAssertEqual(captured.image.width, 40); XCTAssertNil(captured.previousRecordError)
        try await complete(Task { await prepared.waitForCleanup() })
        XCTAssertEqual(cleanups, 1)
        let newer = try await completedResult(Task { try await window.selectWindow() }).get()
        prepared.cancel()
        XCTAssertEqual(cleanups, 1, "Old finished adapter must not call the service's cancellation on its next selection")
        let nextImage = try await completedResult(Task { try await window.capture(newer, showsCursor: false) }).get()
        XCTAssertEqual(nextImage.width, 40)
        XCTAssertEqual(cursors, [true, false]); XCTAssertEqual(cleanups, 2)
    }

    @MainActor
    func testProductionPreviousAdapterCapturesRememberedRegionWithoutPresentation() async throws {
        let f = try NativeFixture(); defer { f.remove() }
        let display = RegionDisplay(id: "A", runtimeID: 1, frame: RegionRect(x: -100, y: 0, width: 100, height: 100),
            scale: 2, rotation: 0, backingWidth: 200, backingHeight: 200)
        let selection = try RegionGeometry.select(drag: RegionRect(x: -90, y: 70, width: 20, height: 10), displays: [display])
        try PreviousRegionRecordStore(fileURL: f.record).remember(selection)
        var cursor: Bool?
        f.captureBody = { configuration in cursor = configuration.showsCursor; return try Self.image() }
        let prepared = try await completedResult(Task {
            try await f.adapter.prepare(mode: .previous, windows: [], cancelShortcut: f.settings.binding)
        }).get()
        let captured = try await completedResult(Task { try await prepared.capture(showsCursor: true) }).get()
        try await complete(Task { await prepared.waitForCleanup() })
        XCTAssertEqual(captured.image.width, 40); XCTAssertNil(captured.previousRecordError)
        XCTAssertEqual(cursor, true); XCTAssertEqual(f.presentations, 0)
        XCTAssertEqual(try PreviousRegionRecordStore(fileURL: f.record).load(), selection)
    }

    @MainActor
    func testFreshAdapterT13BusyDrainsOnlyItsOwnRegionAndLeavesForeignCaptureUsable() async throws {
        let f = try NativeFixture(); let other = try NativeFixture()
        defer { f.remove(); other.remove() }
        let own = try await f.adapter.prepare(mode: .region, windows: [], cancelShortcut: f.settings.binding)
        defer { own.cancel() }
        let foreignRegion = try await other.region.select(cancelShortcut: other.settings.binding)
        let gate = Gate<CGImage>(); defer { gate.fail() }
        other.captureBody = { _ in try await gate.run() }
        let foreign = Task { try await f.previous.capture(foreignRegion, showsCursor: false) }
        defer { foreign.cancel() }
        try await gate.waitStarted()
        let rejected = try await completedResult(Task { try await own.capture(showsCursor: false) })
        do { _ = try rejected.get(); XCTFail("Busy T13 holder adopted fresh capture") }
        catch { XCTAssertEqual(error as? PreviousRegionError, .busy) }
        // This completion must be independent of the still-suspended foreign T13 capture.
        try await complete(Task { await own.waitForCleanup() })
        XCTAssertEqual(f.panelCloses, 1)
        XCTAssertEqual(other.panelCloses, 0)
        gate.finish(.success(try Self.image()))
        let result = try await completedResult(foreign).get()
        XCTAssertEqual(result.image.width, 40)
        XCTAssertNil(result.previousRecordError)
        XCTAssertEqual(other.panelCloses, 1)
    }

    private enum Injected: Error, Equatable { case failed, timeout }
    @MainActor private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    @MainActor private func acknowledge(_ expectation: XCTestExpectation) async throws {
        let outcome = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(outcome, .completed)
        guard outcome == .completed else { throw Injected.timeout }
    }
    @MainActor private func completedResult<Value>(_ task: Task<Value, Error>) async throws -> Result<Value, Error> {
        let finished = XCTestExpectation(description: "Operation completed")
        let observer = Task { let result = await task.result; finished.fulfill(); return result }
        do { try await acknowledge(finished) }
        catch { task.cancel(); observer.cancel(); throw error }
        return await observer.value
    }
    @MainActor private func complete(_ task: Task<Void, Never>) async throws {
        let finished = XCTestExpectation(description: "Cleanup observer completed")
        let observer = Task { await task.value; finished.fulfill() }
        do { try await acknowledge(finished) }
        catch { task.cancel(); observer.cancel(); throw error }
        await observer.value
    }
    @MainActor private func idle(_ runtime: AppRuntime) async throws {
        let task = Task { await runtime.waitUntilIdle() }
        do { try await complete(task) }
        catch { runtime.cancelCapture(); throw error }
        XCTAssertEqual(runtime.activity, .idle)
    }

    @MainActor private final class Gate<Value> {
        let entered = XCTestExpectation(description: "Controlled dependency entered")
        private var didStart = false
        private var pending: CheckedContinuation<Value, Error>?
        private var early: Result<Value, Error>?
        func run() async throws -> Value {
            precondition(!didStart); didStart = true; entered.fulfill()
            if let early { return try early.get() }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func waitStarted() async throws {
            if didStart { return }
            let outcome = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            XCTAssertEqual(outcome, .completed)
            guard outcome == .completed else { fail(); throw Injected.timeout }
        }
        func finish(_ result: Result<Value, Error>) { early = result; let continuation = pending; pending = nil; continuation?.resume(with: result) }
        func fail() { finish(.failure(Injected.failed)) }
    }

    @MainActor private final class Fixture {
        let suite = "getGamen.CaptureOperationTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        let captureSettings: CaptureSettings
        let exportSettings: ExportSettings
        let store: DocumentStore
        let exports: AutomaticExportCoordinator
        let editorWindows: EditorWindowCoordinator
        let binding = HotKeyShortcut(keyCode: 53, modifiers: 0)
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-operation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            captureSettings = CaptureSettings(defaults: defaults)
            exportSettings = ExportSettings(defaults: defaults, defaultFolder: root.appendingPathComponent("getGamen", isDirectory: true))
            store = try DocumentStore(root: root.appendingPathComponent("documents", isDirectory: true))
            exports = try AutomaticExportCoordinator(receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true))
            editorWindows = EditorWindowCoordinator(store: store, exports: exports, settings: exportSettings)
        }
        func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }

    @MainActor private final class NativeFixture {
        let settings: Fixture
        let failRemember: Bool
        var record: URL { settings.root.appendingPathComponent("previous.json") }
        var prepareBody: (() async throws -> RegionExclusionLease)?
        var captureBody: ((SCStreamConfiguration) async throws -> CGImage)?
        var snapshots = 0; var captures = 0; var presentations = 0; var panelCloses = 0
        var permissionCalls = 0; var windowBegins = 0
        var presets: [RegionRect] = []
        let hidden = XCTestExpectation(description: "Owned region panels hidden")
        var hiddenOnce = false
        lazy var service = RegionCaptureService(dependencies: RegionCaptureDependencies(
            preflight: { [weak self] in self?.permissionCalls += 1; return true }, request: { XCTFail("Unexpected permission request"); return false },
            snapshot: { [weak self] in
                guard let self else { throw CancellationError() }; snapshots += 1
                let display = RegionDisplay(id: "A", runtimeID: 1, frame: RegionRect(x: -100, y: 0, width: 100, height: 100),
                    scale: 2, rotation: 0, backingWidth: 200, backingHeight: 200)
                return RegionCaptureSnapshot(displays: [display], capture: { [weak self] _, _, configuration in
                    guard let self else { throw CancellationError() }
                    captures += 1
                    if let captureBody { return try await captureBody(configuration) }
                    return try CaptureOperationTests.image()
                })
            }, prepare: { [weak self] _ in
                guard let self else { throw CancellationError() }
                if let prepareBody { return try await prepareBody() }
                return RegionExclusionLease(excludedWindows: [], validate: {})
            }))
        lazy var region = RegionSelectionController(captureService: service, presentation: RegionSelectionPresentation(present: { [weak self] _, _, send in
            guard let self else { throw CancellationError() }; presentations += 1
            send(.began(CGPoint(x: -90, y: 70))); send(.ended(CGPoint(x: -70, y: 80)))
            return RegionSelectionPanels(windows: [], update: { _, _ in }, hide: { [weak self] in
                guard let self, !hiddenOnce else { return }; hiddenOnce = true; hidden.fulfill()
            }, close: { [weak self] in self?.panelCloses += 1 },
                preset: { [weak self] in self?.presets.append($0) })
        }))
        lazy var window = WindowCaptureService(dependencies: WindowCaptureDependencies(begin: { [weak self] _, _ in
            self?.windowBegins += 1; throw Injected.failed
        }))
        private var previousStorage: PreviousRegionController?
        var previous: PreviousRegionController { previousStorage! }
        var adapter: CapturePreparation {
            CapturePreparation(windowService: window, regionController: region, previousController: previousStorage!)
        }
        init(failRemember: Bool = false) throws {
            settings = try Fixture(); self.failRemember = failRemember
            previousStorage = try PreviousRegionController(captureService: service, recordURL: record,
                beforeAtomicWrite: { if failRemember { throw Injected.failed } })
        }
        func remove() { settings.remove() }
    }
}
