import AppKit

@MainActor
enum RegionSelectionEvent {
    case began(CGPoint), changed(CGPoint), ended(CGPoint)
    case cancelled, topologyChanged, failed(Error), copyRequested
}

/// Keeps native pointer release separate from the controller's final selection event.
@MainActor
final class RegionSelectionAdjustment {
    private(set) var rect: CGRect?
    private var start: CGPoint?
    private var original: CGRect?
    private var edges: (Bool, Bool, Bool, Bool)?
    private var moving = false
    private var dragging = false
    let action: (RegionSelectionEvent) -> Void

    init(action: @escaping (RegionSelectionEvent) -> Void) { self.action = action }

    func receive(_ event: RegionSelectionEvent) {
        switch event {
        case .began(let point):
            start = point; original = rect; dragging = true; moving = false; edges = nil
            if let rect, rect.insetBy(dx: -7, dy: -7).contains(point) {
                let hit = (abs(point.x - rect.minX) <= 7, abs(point.x - rect.maxX) <= 7,
                           abs(point.y - rect.minY) <= 7, abs(point.y - rect.maxY) <= 7)
                if hit.0 || hit.1 || hit.2 || hit.3 { edges = hit }
                else { moving = true }
            }
            update(point)
        case .changed(let point): if dragging { update(point) }
        case .ended(let point):
            if dragging { update(point) }
            dragging = false
        default: action(event)
        }
    }

    private func update(_ point: CGPoint) {
        guard let start else { return }
        if moving, let original {
            rect = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        } else if let edges, let original {
            let x1 = edges.0 ? point.x : original.minX
            let x2 = edges.1 ? point.x : original.maxX
            let y1 = edges.2 ? point.y : original.minY
            let y2 = edges.3 ? point.y : original.maxY
            rect = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2-x1), height: abs(y2-y1))
        } else {
            rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x-start.x), height: abs(point.y-start.y))
        }
        guard let rect else { return }
        action(.began(CGPoint(x: rect.minX, y: rect.minY)))
        action(.changed(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    func preset(_ rect: CGRect) { self.rect = rect }

    func confirm(copy: Bool = false) {
        guard !dragging, let rect, rect.width > 0, rect.height > 0 else { return }
        if copy { action(.copyRequested) }
        action(.ended(CGPoint(x: rect.maxX, y: rect.maxY)))
    }
}

@MainActor
struct RegionSelectionPresentation {
    var present: ([RegionDisplay], HotKeyShortcut?, @escaping @MainActor (RegionSelectionEvent) -> Void) throws -> RegionSelectionPanels

    static let native = RegionSelectionPresentation { displays, shortcut, action in
        try presentNative(displays: displays, shortcut: shortcut, action: action)
    }

    static func presentNative(displays: [RegionDisplay], shortcut: HotKeyShortcut?,
                              screenFacts: @escaping @MainActor () throws -> [ScreenFacts] = currentScreenFacts,
                              action: @escaping @MainActor (RegionSelectionEvent) -> Void) throws -> RegionSelectionPanels {
        try RegionSelectionPanelGroup.present(displays: displays, shortcut: shortcut,
                                              screenFacts: screenFacts, action: action)
    }

    static func canonicalDisplays(_ displays: [RegionDisplay]) throws -> [RegionDisplay] {
        guard let first = displays.first else { throw RegionSelectionError.unavailableScreen }
        // Use the geometry authority for identity, actual mirror group and overlap validation.
        _ = try RegionGeometry.select(drag: first.frame, displays: displays)
        return displays.filter { $0.mirrorSourceID == nil || $0.mirrorSourceID == $0.id }.sorted { $0.id < $1.id }
    }
}

@MainActor
struct RegionSelectionPanels {
    var windows: [NSWindow]
    var update: @MainActor (RegionRect?, PixelSize?) -> Void
    var hide: @MainActor () -> Void
    var close: @MainActor () -> Void
    var cancelVisible: @MainActor () -> Void = {}
    var preset: @MainActor (RegionRect) -> Void = { _ in }
}

@MainActor
final class RegionSelectionPanel: NSPanel {
    let cancelShortcut: HotKeyShortcut?
    var onCancel: @MainActor () -> Void
    private var lastConsumedEvent: NSEvent?
    var interactionEnabled = true

    init(frame: CGRect, cancelShortcut: HotKeyShortcut?, onCancel: @escaping @MainActor () -> Void) {
        self.cancelShortcut = cancelShortcut
        self.onCancel = onCancel
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    private func consumeCancel(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard interactionEnabled else { return true }
        if let cancelShortcut, UInt32(event.keyCode) == cancelShortcut.keyCode &&
            HotKeyShortcut.carbonModifiers(from: event.modifierFlags) == cancelShortcut.modifiers {
            if lastConsumedEvent !== event {
                lastConsumedEvent = event
                onCancel()
            }
            return true
        }
        // Suppress AppKit's legacy Escape fallback after rebinding; this adds no cancel binding.
        return event.keyCode == 53
    }

    override func sendEvent(_ event: NSEvent) {
        if consumeCancel(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if consumeCancel(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if consumeCancel(event) { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Keyboard cancellation is dispatched only by the configured matching authority above.
    }
}

@MainActor
final class RegionSelectionView: NSView {
    let dimensionLabel = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "キャンセル", target: nil, action: nil)
    let captureButton = NSButton(title: "撮影", target: nil, action: nil)
    var onConfirm: ((Bool) -> Void)?
    private let action: @MainActor (RegionSelectionEvent) -> Void
    private(set) var selectionRect: CGRect?
    var interactionEnabled = true

    init(frame: CGRect, action: @escaping @MainActor (RegionSelectionEvent) -> Void) {
        self.action = action
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        dimensionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        dimensionLabel.textColor = .labelColor
        dimensionLabel.backgroundColor = .windowBackgroundColor
        dimensionLabel.drawsBackground = true
        dimensionLabel.isSelectable = false
        dimensionLabel.isHidden = true
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = ""
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        addSubview(dimensionLabel)
        addSubview(cancelButton)
        captureButton.title = ""
        captureButton.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "撮影")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        captureButton.imagePosition = .imageOnly
        captureButton.imageScaling = .scaleNone
        captureButton.isBordered = false
        captureButton.wantsLayer = true
        captureButton.layer?.backgroundColor = NSColor.systemOrange.cgColor
        captureButton.layer?.cornerRadius = 10
        captureButton.contentTintColor = .white
        captureButton.setAccessibilityLabel("撮影")
        captureButton.toolTip = "撮影（Return）／コピー（⌘C）"
        captureButton.isHidden = true
        captureButton.bezelStyle = .rounded
        captureButton.keyEquivalent = "\r"
        captureButton.target = self
        captureButton.action = #selector(capturePressed(_:))
        captureButton.isEnabled = false
        addSubview(captureButton)
        needsLayout = true
    }

    required init?(coder: NSCoder) { return nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func cancelPressed(_ sender: Any?) {
        if interactionEnabled { action(.cancelled) }
    }

    @objc private func capturePressed(_ sender: Any?) {
        if interactionEnabled { onConfirm?(false) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 8, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            if interactionEnabled, captureButton.isEnabled { onConfirm?(true) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { capturePressed(nil) }
        else { super.keyDown(with: event) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // A read-only dimension label must not intercept the drag underneath it.
        return hit === dimensionLabel ? self : hit
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint? {
        guard interactionEnabled else { return nil }
        guard let window = event.window,
              event.locationInWindow.x.isFinite, event.locationInWindow.y.isFinite else {
            action(.failed(RegionSelectionError.invalidSelection))
            return nil
        }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        guard point.x.isFinite, point.y.isFinite else {
            action(.failed(RegionSelectionError.invalidSelection))
            return nil
        }
        return point
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard !cancelButton.frame.contains(local), (captureButton.isHidden || !captureButton.frame.contains(local)), let point = globalPoint(event) else { return }
        event.window?.makeKey()
        event.window?.makeFirstResponder(self)
        action(.began(point))
    }

    override func mouseDragged(with event: NSEvent) {
        if let point = globalPoint(event) { action(.changed(point)) }
    }

    override func mouseUp(with event: NSEvent) {
        if let point = globalPoint(event) { action(.ended(point)) }
    }

    func update(rect: RegionRect?, pixelSize: PixelSize?) {
        selectionRect = nil
        if let rect, let window {
            let endX = rect.x + rect.width, endY = rect.y + rect.height
            if [rect.x, rect.y, endX, endY].allSatisfy(\.isFinite) {
                let global = CGRect(x: min(rect.x, endX), y: min(rect.y, endY),
                                    width: abs(rect.width), height: abs(rect.height))
                let local = convert(window.convertFromScreen(global), from: nil).intersection(bounds)
                if !local.isNull, !local.isEmpty { selectionRect = local }
            }
        }
        dimensionLabel.stringValue = pixelSize.map { "\($0.width) × \($0.height) px" } ?? ""
        dimensionLabel.isHidden = pixelSize == nil || selectionRect == nil
        captureButton.isHidden = dimensionLabel.isHidden
        captureButton.isEnabled = pixelSize != nil
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        cancelButton.sizeToFit()
        let buttonWidth = min(cancelButton.frame.width, max(0, bounds.width - 2 * inset))
        let buttonHeight = min(cancelButton.frame.height, max(0, bounds.height - 2 * inset))
        cancelButton.frame = CGRect(x: max(0, bounds.maxX - inset - buttonWidth),
                                    y: max(0, bounds.maxY - inset - buttonHeight),
                                    width: buttonWidth, height: buttonHeight)
        guard let selectionRect, !dimensionLabel.isHidden else { return }
        dimensionLabel.sizeToFit()
        let labelWidth = dimensionLabel.frame.width
        let labelHeight = dimensionLabel.frame.height
        let buttonSize = CGSize(width: 52, height: 44)
        let gap: CGFloat = 8
        let totalWidth = max(labelWidth, buttonSize.width)
        let totalHeight = buttonSize.height + gap + labelHeight
        let fitsInside = selectionRect.width >= totalWidth + 16 && selectionRect.height >= totalHeight + 16
        let desiredX = selectionRect.midX - totalWidth / 2
        let x = min(max(8, desiredX), max(8, bounds.maxX - totalWidth - 8))
        // Keep very small selections usable: place controls immediately below the selection.
        let desiredY = fitsInside ? selectionRect.midY - totalHeight / 2 : selectionRect.minY - totalHeight - 8
        let y = min(max(8, desiredY), max(8, bounds.maxY - totalHeight - 8))
        dimensionLabel.frame = CGRect(x: x + (totalWidth - labelWidth) / 2, y: y,
                                      width: labelWidth, height: labelHeight)
        captureButton.frame = CGRect(x: x + (totalWidth - buttonSize.width) / 2, y: y + labelHeight + gap,
                                     width: buttonSize.width, height: buttonSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        let dimming = NSBezierPath(rect: bounds)
        if let selectionRect { dimming.append(NSBezierPath(rect: selectionRect)) }
        dimming.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dimming.fill()
        if let selectionRect {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selectionRect.insetBy(dx: min(0.5, selectionRect.width / 2),
                                                               dy: min(0.5, selectionRect.height / 2)))
            border.lineWidth = 1
            border.stroke()
            NSColor.white.setFill()
            for x in [selectionRect.minX, selectionRect.midX, selectionRect.maxX] {
                for y in [selectionRect.minY, selectionRect.midY, selectionRect.maxY] {
                    if x == selectionRect.midX && y == selectionRect.midY { continue }
                    NSBezierPath(rect: CGRect(x: x-3, y: y-3, width: 6, height: 6)).fill()
                }
            }
        }
    }
}

@MainActor
private final class RegionSelectionPanelGroup: NSObject {
    private var panels: [RegionSelectionPanel] = []
    /// Non-nil while observing screen changes.
    private var screenChangeFilter: ScreenChangeFilter?
    private var hidden = false
    private var closed = false
    private var restoreKeyOnHide = false
    private weak var previousKeyWindow: NSWindow?
    private let action: @MainActor (RegionSelectionEvent) -> Void
    private lazy var adjustment = RegionSelectionAdjustment { [weak self] in self?.action($0) }

    private init(action: @escaping @MainActor (RegionSelectionEvent) -> Void) {
        self.action = action
        previousKeyWindow = NSApp.keyWindow
        super.init()
    }

    static func present(displays: [RegionDisplay], shortcut: HotKeyShortcut?,
                        screenFacts: @escaping @MainActor () throws -> [ScreenFacts],
                        action: @escaping @MainActor (RegionSelectionEvent) -> Void) throws -> RegionSelectionPanels {
        let canonical = try RegionSelectionPresentation.canonicalDisplays(displays)
        let group = RegionSelectionPanelGroup(action: action)
        do {
            let screens = try matchingScreens(displays)
            for display in canonical {
                guard let screen = screens[display.runtimeID] else { throw RegionSelectionError.unavailableScreen }
                let panel = RegionSelectionPanel(frame: screen.frame, cancelShortcut: shortcut) { [weak group] in
                    group?.emit(.cancelled)
                }
                panel.contentView = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size)) { [weak group] event in
                    group?.emit(event)
                }
                (panel.contentView as? RegionSelectionView)?.onConfirm = { [weak group] copy in
                    guard let group, !group.hidden, !group.closed else { return }
                    group.adjustment.confirm(copy: copy)
                }
                group.panels.append(panel)
            }
            _ = try matchingScreens(displays)
            group.screenChangeFilter = ScreenChangeFilter(facts: screenFacts)
            NotificationCenter.default.addObserver(group, selector: #selector(screenChanged(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            for panel in group.panels { panel.orderFront(nil) }
            NSApp.activate()
            let initial = group.panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? group.panels.first
            initial?.makeKeyAndOrderFront(nil)
            if let view = initial?.contentView { initial?.makeFirstResponder(view) }
            return RegionSelectionPanels(windows: group.panels,
                update: { rect, size in group.update(rect, size) },
                hide: { group.hide() }, close: { group.close() },
                cancelVisible: { group.restoreKeyOnHide = true; group.hide() },
                preset: { rect in
                    group.adjustment.preset(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
                })
        } catch {
            group.close()
            throw error
        }
    }

    private static func matchingScreens(_ displays: [RegionDisplay]) throws -> [UInt32: NSScreen] {
        var screens: [UInt32: NSScreen] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let id = UInt32(exactly: number.doubleValue), id > 0, screens[id] == nil else {
                throw RegionSelectionError.unavailableScreen
            }
            screens[id] = screen
        }
        guard Set(screens.keys) == Set(displays.map(\.runtimeID)) else { throw RegionSelectionError.unavailableScreen }
        for display in displays {
            guard let screen = screens[display.runtimeID],
                  screen.frame == CGRect(x: display.frame.x, y: display.frame.y,
                                         width: display.frame.width, height: display.frame.height) else {
                throw RegionSelectionError.unavailableScreen
            }
        }
        return screens
    }

    private func emit(_ event: RegionSelectionEvent) {
        guard !hidden, !closed else { return }
        if case .cancelled = event { restoreKeyOnHide = true }
        adjustment.receive(event)
    }

    @objc private func screenChanged(_ notification: Notification) {
        guard let screenChangeFilter, screenChangeFilter.changed() else { return }
        emit(.topologyChanged)
    }

    private func update(_ rect: RegionRect?, _ size: PixelSize?) {
        guard !hidden, !closed else { return }
        for panel in panels { (panel.contentView as? RegionSelectionView)?.update(rect: rect, pixelSize: size) }
    }

    private func hide() {
        guard !hidden else { return }
        hidden = true
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        screenChangeFilter = nil
        for panel in panels {
            panel.interactionEnabled = false
            (panel.contentView as? RegionSelectionView)?.interactionEnabled = false
            panel.orderOut(nil)
        }
        if restoreKeyOnHide, let previousKeyWindow, previousKeyWindow.isVisible,
           NSApp.windows.contains(where: { $0 === previousKeyWindow }) {
            previousKeyWindow.makeKey()
        }
    }

    private func close() {
        guard !closed else { return }
        hide()
        closed = true
        for panel in panels { panel.close() }
        panels.removeAll()
    }
}
