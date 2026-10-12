import AppKit
import XCTest
@testable import GetGamen
@testable import GetGamenCore

/// Native windows plus injected capture transport; actual focus/Dock checks belong to the UI host.
final class CaptureChooserControllerTests: XCTestCase {
    @MainActor
    func testMayShowFalseKeepsChooserHiddenOnShowAndDockReopen() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let runtime = fixture.runtime()
        var commands: [AppCommand] = []
        let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { commands.append($0) }
        defer { controller.window.orderOut(nil) }
        controller.mayShow = { false }
        controller.show()
        XCTAssertFalse(controller.window.isVisible)
        controller.reopenFromDock()
        XCTAssertFalse(controller.window.isVisible)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(controller.window.level, .normal)
        XCTAssertThrowsError(try controller.start(.window)) { error in
            XCTAssertEqual(error as? CaptureOperationError, .busy)
        }
        controller.mayShow = { true }
        controller.show()
        XCTAssertTrue(controller.window.isVisible)
        controller.window.orderOut(nil)
        controller.reopenFromDock()
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertEqual(commands, [.chooser])
    }

    @MainActor
    func testChooserReusesWindowAndDockEntersCommonRoute() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let runtime = fixture.runtime()
        var commands: [AppCommand] = []
        let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { commands.append($0) }
        defer { controller.window.orderOut(nil) }
        controller.show()
        let number = controller.window.windowNumber
        controller.show()
        XCTAssertEqual(controller.window.windowNumber, number)
        XCTAssertTrue(controller.window.isVisible)
        controller.reopenFromDock()
        XCTAssertEqual(commands, [.chooser])
        XCTAssertFalse(controller.windowShouldClose(controller.window))
        XCTAssertFalse(controller.window.isVisible)
        controller.show()
        XCTAssertEqual(controller.window.windowNumber, number)
    }

    @MainActor
    func testDockReopenRestoresHiddenChooserThroughRouter() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let runtime = fixture.runtime()
        var controller: CaptureChooserController!
        controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { command in
            if command == .chooser { controller.show() }
        }
        defer { controller.window.orderOut(nil); controller = nil }
        controller.show()
        let number = controller.window.windowNumber
        controller.window.orderOut(nil)
        XCTAssertFalse(controller.window.isVisible)
        controller.reopenFromDock()
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertEqual(controller.window.windowNumber, number)
    }

    @MainActor
    func testChooserPositionSurvivesCloseAndControllerRecreation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var first: CaptureChooserController? = CaptureChooserController(
            runtime: fixture.runtime(), defaults: fixture.defaults) { _ in }
        first!.show()
        let original = first!.window.frame
        first!.window.setFrameOrigin(NSPoint(x: original.origin.x + 35, y: original.origin.y - 30))
        let moved = first!.window.frame
        XCTAssertNotEqual(original.origin, moved.origin)
        XCTAssertFalse(first!.windowShouldClose(first!.window))
        first!.show()
        XCTAssertEqual(first!.window.frame.origin, moved.origin)
        first!.window.orderOut(nil)
        first = nil
        let restored = CaptureChooserController(runtime: fixture.runtime(), defaults: fixture.defaults) { _ in }
        defer { restored.window.orderOut(nil) }
        restored.show()
        XCTAssertEqual(restored.window.frame.origin.x, moved.origin.x, accuracy: 1)
        XCTAssertEqual(restored.window.frame.origin.y, moved.origin.y, accuracy: 1)
    }

    @MainActor
    func testDockRestoresLastModeAcrossControllerRecreation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let commands: [CaptureMode: AppCommand] = [.window: .captureWindow, .region: .captureRegion,
                                                   .previous: .capturePrevious, .scroll: .captureScroll]
        for (mode, expected) in commands {
            var routed: [AppCommand] = []
            let first = CaptureChooserController(runtime: fixture.runtime(), defaults: fixture.defaults) { _ in }
            first.remember(mode)
            let restored = CaptureChooserController(runtime: fixture.runtime(), defaults: fixture.defaults) { routed.append($0) }
            restored.reopenFromDock()
            XCTAssertEqual(routed, [expected])
        }
        fixture.defaults.set("invalid", forKey: "getGamen.capture.lastMode")
        var routed: [AppCommand] = []
        let fallback = CaptureChooserController(runtime: fixture.runtime(), defaults: fixture.defaults) { routed.append($0) }
        fallback.reopenFromDock()
        XCTAssertEqual(routed, [.chooser])
    }

    @MainActor
    func testPersistentOutlineIsClickThroughAndSurvivesUnchangedScreenNotifications() {
        let outline = CapturedRegionOutline()
        outline.show(frame: NSRect(x: 100, y: 100, width: 200, height: 100))
        XCTAssertTrue(outline.isVisible)
        XCTAssertTrue(outline.window?.ignoresMouseEvents == true)
        XCTAssertEqual(outline.window?.frame, NSRect(x: 97, y: 97, width: 206, height: 106))
        // The screens did not change, as at launch (#28); a real change is covered by ScreenChangeFilterTests.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(outline.isVisible)
        outline.clear()
        XCTAssertFalse(outline.isVisible)
        XCTAssertNil(outline.window)
    }

    @MainActor
    func testVisibleExclusionCountdownThenSynchronousHideForAllDelays() async throws {
        for seconds in [0, 1, 10] {
            let fixture = try Fixture(); defer { fixture.remove() }
            try fixture.capture.setTimerSeconds(seconds)
            var excluded: NSWindow?
            var sequence: [String] = []
            let runtime = fixture.runtime(prepare: { _, windows, _ in
                let window = try XCTUnwrap(windows.first)
                XCTAssertEqual(windows.count, 1)
                XCTAssertTrue(window.isVisible)
                XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.screenSaver.rawValue)
                excluded = window
                sequence.append("select")
                return PreparedCapture(capture: { _ in
                    XCTAssertFalse(window.isVisible)
                    sequence.append("capture")
                    return CapturedImage(image: try Self.image(), previousRecordError: nil)
                }, cancel: {}, waitForCleanup: {
                    XCTAssertEqual(excluded?.windowNumber, window.windowNumber)
                    sequence.append("cleanup")
                })
            }, wait: { value, emit in
                XCTAssertEqual(value, seconds)
                sequence.append("countdown")
                emit(seconds)
                if seconds > 0 { XCTAssertTrue(excluded?.isVisible == true) }
                emit(0)
            }, delivery: { _, _ in sequence.append("deliver") })
            let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { _ in }
            defer { controller.window.orderOut(nil) }
            try controller.start(.region)
            XCTAssertThrowsError(try controller.start(.window))
            await runtime.waitUntilIdle()
            XCTAssertEqual(sequence, ["select", "countdown", "capture", "deliver", "cleanup"])
            XCTAssertFalse(controller.window.isVisible)
            XCTAssertEqual(controller.window.level, .normal)
        }
    }

    @MainActor
    func testToolbarSwitchWaitsForCancellationCleanup() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let waiting = expectation(description: "countdown")
        let switched = expectation(description: "new mode routed")
        var finish: CheckedContinuation<Void, Never>?
        var cleaned = false
        var routed: [AppCommand] = []
        let runtime = fixture.runtime(prepare: { _, _, _ in
            PreparedCapture(capture: { _ in throw CancellationError() }, cancel: {},
                            waitForCleanup: { cleaned = true })
        }, wait: { _, emit in
            emit(10)
            await withCheckedContinuation { finish = $0; waiting.fulfill() }
        })
        let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { command in
            XCTAssertTrue(cleaned)
            routed.append(command)
            switched.fulfill()
        }
        defer { controller.window.orderOut(nil) }
        try controller.start(.window)
        await fulfillment(of: [waiting], timeout: 2)
        controller.performFromToolbar(.captureRegion)
        XCTAssertTrue(routed.isEmpty)
        finish?.resume()
        await fulfillment(of: [switched], timeout: 2)
        XCTAssertEqual(routed, [.captureRegion])
    }

    @MainActor
    func testTimerChangesPreservePendingSelectionAndUseLatestDelay() async throws {
        for mode in [CaptureMode.region, .window, .previous] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let selecting = expectation(description: "selection ready")
            var finish: CheckedContinuation<Void, Never>?
            var preparations = 0, captures = 0, cleanups = 0
            let runtime = fixture.runtime(prepare: { _, _, _ in
                preparations += 1
                await withCheckedContinuation { finish = $0; selecting.fulfill() }
                return PreparedCapture(capture: { _ in
                    captures += 1
                    return CapturedImage(image: try Self.image(), previousRecordError: nil)
                }, cancel: { XCTFail("Timer change cancelled selection") },
                waitForCleanup: { cleanups += 1 })
            }, wait: { seconds, emit in
                XCTAssertEqual(seconds, 5)
                emit(seconds); emit(0)
            }, delivery: { _, intent in
                XCTAssertEqual(intent.mode, mode)
                XCTAssertEqual(intent.capture.timerSeconds, 5)
            })
            let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { _ in
                XCTFail("Timer change restarted capture")
            }
            defer { controller.window.orderOut(nil) }
            try controller.start(mode)
            await fulfillment(of: [selecting], timeout: 2)
            for seconds in [3, 12, 0, 5] {
                controller.selectTimer(seconds)
                XCTAssertEqual(runtime.activity, .selecting)
                XCTAssertEqual(fixture.capture.snapshot.timerSeconds, seconds)
            }
            XCTAssertEqual(preparations, 1)
            XCTAssertEqual(captures, 0)
            finish?.resume()
            await runtime.waitUntilIdle()
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(cleanups, 1)
        }
    }

    @MainActor
    func testTimerToggleRestartsSameModeAfterCleanupWithUpdatedDelay() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let waiting = expectation(description: "countdown")
        let switched = expectation(description: "new mode routed")
        var finish: CheckedContinuation<Void, Never>?
        var cleaned = false
        var routed: [AppCommand] = []
        let runtime = fixture.runtime(prepare: { _, _, _ in
            PreparedCapture(capture: { _ in throw CancellationError() }, cancel: {},
                            waitForCleanup: { cleaned = true })
        }, wait: { _, emit in
            emit(10)
            await withCheckedContinuation { finish = $0; waiting.fulfill() }
        })
        let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { command in
            XCTAssertTrue(cleaned)
            routed.append(command)
            switched.fulfill()
        }
        defer { controller.window.orderOut(nil) }
        try controller.start(.window)
        await fulfillment(of: [waiting], timeout: 2)
        controller.selectTimer(12)
        XCTAssertEqual(fixture.capture.snapshot.timerSeconds, 12)
        XCTAssertTrue(routed.isEmpty)
        finish?.resume()
        await fulfillment(of: [switched], timeout: 2)
        XCTAssertEqual(routed, [.captureWindow])
    }

    @MainActor
    func testDockChooserReturnsAfterCaptureAndExplicitCloseDismissesIt() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let runtime = fixture.runtime(prepare: { _, _, _ in
            PreparedCapture(capture: { _ in
                CapturedImage(image: try Self.image(), previousRecordError: nil)
            }, cancel: {}, waitForCleanup: {})
        })
        let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { _ in }
        defer { controller.window.orderOut(nil) }
        controller.reopenFromDock()
        try controller.start(.window)
        await runtime.waitUntilIdle()
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertEqual(controller.lastMode, .window)
        XCTAssertFalse(controller.windowShouldClose(controller.window))
        XCTAssertFalse(controller.window.isVisible)
    }

    @MainActor
    func testCloseCancelsAndWaitsForOwnedCleanupWithoutDestroyingWindow() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let waiting = expectation(description: "countdown started")
        var finish: CheckedContinuation<Void, Never>?
        var captures = 0, cleanups = 0
        let runtime = fixture.runtime(prepare: { _, _, _ in
            PreparedCapture(capture: { _ in captures += 1; throw CancellationError() },
                cancel: {}, waitForCleanup: { cleanups += 1 })
        }, wait: { _, emit in
            emit(10)
            await withCheckedContinuation { continuation in finish = continuation; waiting.fulfill() }
            emit(0) // stale notification after cancel must not revive presentation
        })
        let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { _ in }
        defer { controller.window.orderOut(nil) }
        try controller.start(.previous)
        await fulfillment(of: [waiting], timeout: 2)
        let number = controller.window.windowNumber
        XCTAssertFalse(controller.windowShouldClose(controller.window))
        XCTAssertEqual(runtime.activity, .cancelling)
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertThrowsError(try controller.start(.window))
        finish?.resume()
        await runtime.waitUntilIdle()
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(cleanups, 1)
        XCTAssertFalse(controller.window.isVisible)
        XCTAssertEqual(controller.window.windowNumber, number)
    }

    @MainActor
    func testPreviousFailureOffersReselectionAndPermissionFailureDoesNot() async throws {
        let errors: [Error] = [PreviousRegionError.missingPrevious, PreviousRegionError.corruptRecord,
                              PreviousRegionError.reselectionRequired(.topologyChanged),
                              RegionCaptureError.permissionRequired]
        for error in errors {
            let fixture = try Fixture(); defer { fixture.remove() }
            let runtime = fixture.runtime(prepare: { _, _, _ in throw error })
            let controller = CaptureChooserController(runtime: runtime, defaults: fixture.defaults) { _ in }
            defer { controller.window.orderOut(nil) }
            try controller.start(.previous)
            await runtime.waitUntilIdle()
            XCTAssertTrue(controller.window.isVisible)
            XCTAssertNotNil(runtime.failureMessage)
            XCTAssertEqual(runtime.failureNeedsReselection, error is PreviousRegionError)
        }
    }

    @MainActor private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor private final class Fixture {
        let suite = "getGamen.ChooserTests.\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-chooser-\(UUID())")
        let defaults: UserDefaults
        let capture: CaptureSettings
        let export: ExportSettings
        let editors: EditorWindowCoordinator
        init() throws {
            _ = NSApplication.shared
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            capture = CaptureSettings(defaults: defaults)
            export = ExportSettings(defaults: defaults)
            let store = try DocumentStore(root: root.appendingPathComponent("documents"))
            let exports = try AutomaticExportCoordinator(receiptsRoot: root.appendingPathComponent("receipts"))
            editors = EditorWindowCoordinator(store: store, exports: exports, settings: export)
        }
        func runtime(
            prepare: @escaping @MainActor (CaptureMode, [NSWindow], HotKeyShortcut?) async throws -> PreparedCapture = { _, _, _ in throw CancellationError() },
            wait: @escaping @MainActor (Int, @escaping @MainActor (Int) -> Void) async throws -> Void = { _, emit in emit(0) },
            delivery: @escaping @MainActor (CapturedImage, CaptureIntent) async throws -> Void = { _, _ in }
        ) -> AppRuntime {
            AppRuntime(captureSettings: capture, exportSettings: export, editorWindows: editors,
                       cancelShortcut: HotKeyShortcut(keyCode: 53, modifiers: 0),
                       prepare: prepare, wait: wait, didCapture: delivery)
        }
        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
