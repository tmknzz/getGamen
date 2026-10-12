import AppKit
import SwiftUI
import GetGamenCore

/// Presentation only. AppRuntime remains the sole owner of each capture and its cleanup.
@MainActor
final class CaptureChooserController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let runtime: AppRuntime
    var mayShow: () -> Bool = { true }
    private let route: @MainActor (AppCommand) -> Void
    private var dismissWhenIdle = false
    private var keepVisibleAfterCapture = false
    private var pendingModeSwitch: UUID?
    private let defaults: UserDefaults
    private let positionKey = "getGamen.captureChooser.position"

    init(runtime: AppRuntime, defaults: UserDefaults = .standard, route: @escaping @MainActor (AppCommand) -> Void) {
        self.defaults = defaults
        self.runtime = runtime
        self.route = route
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CaptureChooserView.width, height: 52),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "getGamen — 撮影"
        window.identifier = NSUserInterfaceItemIdentifier("capture-chooser")
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init()
        window.contentViewController = NSHostingController(rootView: CaptureChooserView(runtime: runtime, selectTimer: { [weak self] seconds in self?.selectTimer(seconds) }) { [weak self] command in
            self?.performFromToolbar(command)
        }.defaultAppStorage(defaults))
        window.center()
        if let saved = defaults.dictionary(forKey: positionKey),
           let x = saved["x"] as? Double, let y = saved["y"] as? Double,
           x.isFinite, y.isFinite {
            let frame = NSRect(origin: NSPoint(x: x, y: y), size: window.frame.size)
            let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(
                    x: max(visible.minX, min(x, visible.maxX - frame.width)),
                    y: max(visible.minY, min(y, visible.maxY - frame.height))))
            }
        }
        window.delegate = self
        runtime.activityDidChange = { [weak self] activity in self?.update(activity) }
    }

    /// Menu, local/global shortcut and Dock reopen all enter through the same router.
    var lastMode: CaptureMode? {
        defaults.string(forKey: "getGamen.capture.lastMode").flatMap(CaptureMode.init(rawValue:))
    }

    func remember(_ mode: CaptureMode) {
        defaults.set(mode.rawValue, forKey: "getGamen.capture.lastMode")
    }

    func reopenFromDock() {
        guard mayShow() else { return }
        keepVisibleAfterCapture = true
        if runtime.activity == .idle { window.level = .floating }
        if runtime.activity != .idle {
            if runtime.activity == .selecting { window.orderFrontRegardless() }
            return
        }
        show()
        switch lastMode {
        case .window: route(.captureWindow)
        case .region: route(.captureRegion)
        case .previous: route(.capturePrevious)
        case .scroll: route(.captureScroll)
        case nil: route(.chooser)
        }
    }

    func show() {
        guard runtime.activity == .idle, mayShow() else { return }
        dismissWhenIdle = false
        // Dock reopen must also restore a minimized chooser before raising it.
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    @discardableResult
    func start(_ mode: CaptureMode, allowsCopyOnly: Bool = true) throws -> UUID {
        guard runtime.activity == .idle, mayShow() else { throw CaptureOperationError.busy }
        // Exclusion acquisition needs this native window visible and numbered.
        // Keep the same window alive through the runtime's cleanup barrier.
        show()
        let operationID = try runtime.startCapture(mode, exclusionWindows: [window], allowsCopyOnly: allowsCopyOnly)
        remember(mode)
        return operationID
    }

    func performFromToolbar(_ command: AppCommand) {
        guard runtime.activity != .idle else { route(command); return }
        guard [.captureWindow, .captureRegion, .capturePrevious, .captureScroll].contains(command) else { return }
        switch runtime.activity {
        case .selecting, .countdown, .cancelling: break
        default: return
        }
        let request = UUID()
        pendingModeSwitch = request
        runtime.cancelCapture()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runtime.waitUntilIdle()
            guard pendingModeSwitch == request else { return }
            pendingModeSwitch = nil
            route(command)
        }
    }

    func selectTimer(_ seconds: Int) {
        switch runtime.activity {
        case .idle, .selecting, .countdown, .cancelling: break
        default: return
        }
        guard [0, 3, 5, 12].contains(seconds) else { return }
        try? runtime.captureSettings.setTimerSeconds(seconds)
        if runtime.activity == .selecting {
            runtime.updateSelectionTimer(seconds)
            return
        }
        guard runtime.activity != .idle else { return }
        // Active captures own a settings snapshot. Restart selection to apply this toggle now.
        switch lastMode {
        case .window: performFromToolbar(.captureWindow)
        case .region: performFromToolbar(.captureRegion)
        case .previous: performFromToolbar(.capturePrevious)
        default: break
        }
    }

    func cancel() { runtime.cancelCapture() }

    private func update(_ activity: CaptureActivity) {
        switch activity {
        case .capturing, .delivering:
            window.orderOut(nil)
        case .idle:
            window.level = keepVisibleAfterCapture ? .floating : .normal
            if dismissWhenIdle {
                window.orderOut(nil)
                dismissWhenIdle = false
            } else if runtime.failureMessage != nil {
                show()
            } else if keepVisibleAfterCapture {
                // Leave keyboard focus in the new editor, including Command+C.
                window.orderFront(nil)
            }
        case .countdown(let seconds):
            if seconds > 0 { window.orderFront(nil) }
        case .selecting:
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.orderFrontRegardless()
        case .cancelling: break
        }
    }

    private func savePosition() {
        defaults.set(["x": window.frame.origin.x, "y": window.frame.origin.y], forKey: positionKey)
    }

    func windowDidMove(_ notification: Notification) {
        savePosition()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        savePosition()
        keepVisibleAfterCapture = false
        pendingModeSwitch = nil
        if runtime.activity != .idle {
            dismissWhenIdle = true
            runtime.cancelCapture()
            return false
        }
        // Reuse the native window; never destroy its number during an exclusion lease.
        window.orderOut(nil)
        return false
    }
}
