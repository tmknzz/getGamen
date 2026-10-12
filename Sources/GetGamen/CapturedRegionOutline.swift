import AppKit
import GetGamenCore

/// A passive indicator, separate from the capture selection's resource lifetime.
@MainActor
final class CapturedRegionOutline {
    private(set) var window: NSPanel?
    private var screenChangeFilter: ScreenChangeFilter?
    var isVisible: Bool { window?.isVisible == true }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// The notification also fires without a real change (e.g. at launch); keep the outline then.
    @objc private func screenChanged() {
        guard let screenChangeFilter, screenChangeFilter.changed() else { return }
        clear()
    }

    func show(_ selection: RegionSelection) {
        clear()
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return false }
            return CFUUIDCreateString(nil, uuid) as String == selection.anchorID
        }) else { return }
        let rect = selection.dragInAnchor
        show(frame: NSRect(x: screen.frame.minX + rect.x,
                           y: screen.frame.maxY - rect.y - rect.height,
                           width: rect.width, height: rect.height))
    }

    func show(frame: NSRect) {
        clear()
        guard frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return }
        let panel = NSPanel(contentRect: frame.insetBy(dx: -3, dy: -3),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = OutlineView(frame: NSRect(origin: .zero, size: panel.frame.size))
        window = panel
        screenChangeFilter = ScreenChangeFilter()
        panel.orderFrontRegardless()
    }

    func clear() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        screenChangeFilter = nil
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
        NSColor.white.setStroke()
        path.lineWidth = 3
        path.stroke()
        NSColor.systemOrange.setStroke()
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}
