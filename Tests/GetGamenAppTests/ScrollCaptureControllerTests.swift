import AppKit
import XCTest
@testable import GetGamen
import GetGamenCore

final class ScrollCaptureControllerTests: XCTestCase {
    @MainActor
    func testCaptureExcludesOnlyScrollWindow() async throws {
        try await withPresentedController { controller, scrollWindow in
            let otherWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            otherWindow.isReleasedWhenClosed = false
            defer { otherWindow.close() }
            otherWindow.orderFrontRegardless()
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            defer { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem.button?.title = "ScrollCaptureTests"

            XCTAssertTrue(scrollWindow.isVisible)
            XCTAssertTrue(otherWindow.isVisible)
            let windows = controller.captureExclusionWindows
            XCTAssertEqual(windows.count, 1)
            let excludedWindow = try XCTUnwrap(windows.first)
            XCTAssertTrue(excludedWindow === scrollWindow)
            XCTAssertEqual(excludedWindow.title, "getGamen — スクロール撮影")
            XCTAssertFalse(windows.contains { $0 === otherWindow })
            XCTAssertFalse(windows.contains { NSStringFromClass(type(of: $0)).contains("StatusBar") })
        }
    }

    @MainActor
    func testWindowRestorationRespectsDismissalAndFreeze() async throws {
        try await withPresentedController { controller, window in
            XCTAssertTrue(controller.shouldRestoreWindow)
            XCTAssertFalse(controller.windowShouldClose(window))
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(controller.shouldRestoreWindow)
            controller.present()
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(controller.shouldRestoreWindow)
            controller.freeze()
            XCTAssertFalse(controller.shouldRestoreWindow)
        }
    }

    @MainActor
    func testCaptureRevealShowsHiddenWindowAndClearsDismissal() async throws {
        try await withPresentedController { controller, window in
            window.orderOut(nil)
            XCTAssertFalse(window.isVisible)
            controller.revealWindowForCapture()
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(controller.shouldRestoreWindow)
            XCTAssertFalse(controller.windowShouldClose(window))
            XCTAssertFalse(controller.shouldRestoreWindow)
            controller.revealWindowForCapture()
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(controller.shouldRestoreWindow)
        }
    }

    @MainActor
    func testCaptureRevealCallsWillStartCaptureOnce() async throws {
        try await withPresentedController { controller, _ in
            var calls = 0
            controller.willStartCapture = { calls += 1 }
            controller.revealWindowForCapture()
            XCTAssertEqual(calls, 1)
        }
    }

    @MainActor
    func testResumeRestoresHiddenWindowUnlessDismissed() async throws {
        try await withPresentedController { controller, window in
            window.orderOut(nil)
            XCTAssertFalse(window.isVisible)
            XCTAssertTrue(controller.shouldRestoreWindow)
            controller.freeze()
            controller.resume()
            XCTAssertTrue(window.isVisible)
            XCTAssertFalse(controller.windowShouldClose(window))
            XCTAssertFalse(window.isVisible)
            controller.freeze()
            controller.resume()
            XCTAssertFalse(window.isVisible)
        }
    }

    @MainActor
    private func withPresentedController(_ body: @MainActor (ScrollCaptureController, NSWindow) throws -> Void) async throws {
        _ = NSApplication.shared
        let suite = "getGamen.ScrollCaptureTests.\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-scroll-\(UUID())")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let capture = CaptureSettings(defaults: defaults)
        let export = ExportSettings(defaults: defaults)
        let store = try DocumentStore(root: root.appendingPathComponent("documents"))
        let exports = try AutomaticExportCoordinator(receiptsRoot: root.appendingPathComponent("receipts"))
        let editors = EditorWindowCoordinator(store: store, exports: exports, settings: export)
        let controller = try ScrollCaptureController(root: root, capture: capture, export: export,
                                                     store: store, editors: editors)
        controller.present()
        defer { for window in controller.captureExclusionWindows { window.close() } }
        await controller.waitUntilIdle()
        let window = try XCTUnwrap(controller.captureExclusionWindows.first)
        try body(controller, window)
    }
}
