import AppKit
import ScreenCaptureKit

public enum DirectWindowPicker {
    public static func isCapturable(layer: Int, width: CGFloat, height: CGFloat,
                                    ownerPID: pid_t?, ownPID: pid_t) -> Bool {
        layer == 0 && width > 1 && height > 1 && ownerPID != ownPID
    }

    @MainActor
    public static func capturableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter {
            isCapturable(layer: $0.windowLayer, width: $0.frame.width, height: $0.frame.height,
                         ownerPID: $0.owningApplication?.processID, ownPID: ownPID)
        }.sorted { $0.windowID < $1.windowID }
    }
}

/// Uses front-to-back Quartz bounds; AppKit points are converted at the boundary.
enum WindowHitTesting {
    static func window(at point: CGPoint, primaryTop: CGFloat, ordered: [(CGWindowID, CGRect)]) -> CGWindowID? {
        let quartz = CGPoint(x: point.x, y: primaryTop - point.y)
        return ordered.first { $0.1.contains(quartz) }?.0
    }
}

@MainActor
final class DirectWindowPickerSession {
    private let exclusions: Set<Int>
    private let receive: @MainActor (WindowPickerEvent) -> Void
    private var task: Task<Void, Never>?
    private var panels: [DirectWindowPanel] = []
    private var windows: [CGWindowID: SCWindow] = [:]
    private var ordered: [(CGWindowID, CGRect)] = []
    private var selected: CGWindowID?
    private var confirmed: CGWindowID?
    private var closed = false
    private var primaryTop: CGFloat = 0
    private let screenChangeFilter: ScreenChangeFilter

    init(exclusions: [Int],
         screenFacts: @escaping @MainActor () throws -> [ScreenFacts] = currentScreenFacts,
         receive: @escaping @MainActor (WindowPickerEvent) -> Void) throws {
        self.exclusions = Set(exclusions)
        self.receive = receive
        screenChangeFilter = ScreenChangeFilter(facts: screenFacts)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelForScreenChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func present() {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                    throw WindowCaptureService.CaptureError.permissionRequired
                }
                let capturable = try await DirectWindowPicker.capturableWindows()
                try Task.checkCancellation()
                guard !closed else { return }
                windows = Dictionary(uniqueKeysWithValues: capturable.filter {
                    !self.exclusions.contains(Int($0.windowID))
                }.map { ($0.windowID, $0) })
                refreshBounds()
                guard !ordered.isEmpty, let primary = NSScreen.screens.first else {
                    throw WindowCaptureService.CaptureError.invalidSelection
                }
                primaryTop = primary.frame.maxY
                for screen in NSScreen.screens {
                    let panel = DirectWindowPanel(contentRect: screen.frame, styleMask: .borderless,
                        backing: .buffered, defer: false)
                    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
                    panel.acceptsMouseMovedEvents = true
                    panel.level = .screenSaver; panel.isReleasedWhenClosed = false
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    let view = DirectWindowView(frame: NSRect(origin: .zero, size: screen.frame.size))
                    view.moved = { [weak self] in self?.hover() }
                    view.clicked = { [weak self] in self?.choose() }
                    view.confirm = { [weak self] copy in self?.capture(copy: copy) }
                    panel.contentView = view
                    panels.append(panel)
                    panel.makeKeyAndOrderFront(nil)
                    panel.makeFirstResponder(view)
                }
                NSApp.activate()
                hover()
            } catch {
                guard !closed else { return }
                close()
                receive(.failed(error))
            }
        }
    }

    private func refreshBounds() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        ordered = list.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? NSNumber,
                  windows[id.uint32Value] != nil,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (id.uint32Value, rect)
        }
    }

    private func hover() {
        refreshBounds()
        guard confirmed == nil else { return }
        selected = WindowHitTesting.window(at: NSEvent.mouseLocation, primaryTop: primaryTop, ordered: ordered)
        let frame = selected.flatMap { id in ordered.first { $0.0 == id }?.1 }.map {
            NSRect(x: $0.minX, y: primaryTop - $0.maxY, width: $0.width, height: $0.height)
        }
        for panel in panels {
            guard let view = panel.contentView as? DirectWindowView else { continue }
            view.highlight = frame.map { panel.convertFromScreen($0) }
            view.needsDisplay = true
        }
    }

    private func choose() {
        confirmed = nil
        for panel in panels { (panel.contentView as? DirectWindowView)?.showControls(size: nil) }
        hover()
        guard let id = selected, let window = windows[id] else { return }
        confirmed = id
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = try? WindowCaptureGeometry.pixelSize(contentRect: filter.contentRect,
                                                       pointPixelScale: Double(filter.pointPixelScale))
        for panel in panels {
            guard let view = panel.contentView as? DirectWindowView else { continue }
            view.showControls(size: size)
        }
    }

    private func capture(copy: Bool) {
        guard !closed, let id = confirmed, let window = windows[id] else { return }
        refreshBounds()
        guard ordered.contains(where: { $0.0 == id }) else {
            confirmed = nil
            for panel in panels { (panel.contentView as? DirectWindowView)?.showControls(size: nil) }
            hover()
            return
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        close()
        receive(.selected(WindowCaptureTarget(geometry: {
            (filter.contentRect, Double(filter.pointPixelScale))
        }, capture: { configuration in
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }, copiesToClipboard: copy)))
    }

    @objc private func cancelForScreenChange() {
        guard !closed, screenChangeFilter.changed() else { return }
        close()
        receive(.cancelled)
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(); task = nil
        NotificationCenter.default.removeObserver(self)
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
    }
}

@MainActor
private final class DirectWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class DirectWindowView: NSView {
    var confirm: ((Bool) -> Void)?
    let camera = NSButton()
    let dimensions = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        camera.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "撮影")?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .semibold))
        camera.imagePosition = .imageOnly
        camera.imageScaling = .scaleNone
        camera.isBordered = false
        camera.wantsLayer = true
        camera.layer?.backgroundColor = NSColor.systemOrange.cgColor
        camera.layer?.cornerRadius = 10
        camera.contentTintColor = .white
        camera.setAccessibilityLabel("撮影")
        camera.toolTip = "撮影（Return）／コピー（⌘C）"
        camera.target = self; camera.action = #selector(takePhoto)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        dimensions.alignment = .center
        dimensions.drawsBackground = true
        dimensions.backgroundColor = .windowBackgroundColor
        addSubview(camera); addSubview(dimensions)
        showControls(size: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showControls(size: PixelSize?) {
        camera.isHidden = size == nil
        dimensions.isHidden = size == nil
        dimensions.stringValue = size.map { "\($0.width) × \($0.height) px" } ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let highlight, !camera.isHidden else { return }
        let visible = highlight.intersection(bounds)
        guard !visible.isNull, !visible.isEmpty else { camera.isHidden = true; dimensions.isHidden = true; return }
        dimensions.sizeToFit()
        let h = 44 + 8 + dimensions.frame.height
        let x = min(max(visible.midX, dimensions.frame.width / 2 + 8), bounds.maxX - dimensions.frame.width / 2 - 8)
        let y = min(max(visible.midY - h / 2, 8), bounds.maxY - h - 8)
        dimensions.frame.origin = CGPoint(x: x - dimensions.frame.width / 2, y: y)
        camera.frame = CGRect(x: x - 26, y: y + dimensions.frame.height + 8, width: 52, height: 44)
    }

    @objc private func takePhoto() { if !camera.isHidden { confirm?(false) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if !camera.isHidden, event.keyCode == 8, modifiers == .command { confirm?(true); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === dimensions ? self : hit
    }
    var moved: (() -> Void)?
    var clicked: (() -> Void)?
    var highlight: NSRect?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { moved?() }
    override func mouseDown(with event: NSEvent) { clicked?() }
    override func keyDown(with event: NSEvent) {
        if performKeyEquivalent(with: event) { return }
        if event.keyCode == 36 || event.keyCode == 76 { takePhoto() }
        // App command router owns cancellation keys.
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill(); bounds.fill()
        if let highlight {
            NSColor.systemOrange.withAlphaComponent(0.15).setFill(); highlight.fill()
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath(rect: highlight.insetBy(dx: 2, dy: 2))
            path.lineWidth = 3; path.stroke()
        }
    }
}
