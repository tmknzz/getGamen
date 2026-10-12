import AppKit
import Observation
import SwiftUI
import GetGamenCore

@MainActor
@Observable
final class EditorViewport {
    enum ZoomMode: Equatable { case fitAll, fitWidth, actualPixels, manual }
    private(set) var mode: ZoomMode = .actualPixels
    private(set) var imageSize: CGSize = .zero
    private(set) var cropOrigin: CGPoint = .zero
    private(set) var viewportSize: CGSize = .zero
    private(set) var backingScale: CGFloat = 1
    private(set) var magnification: CGFloat = 1

    init() {}

    func updateImage(size: CGSize, cropOrigin: CGPoint) {
        guard Self.valid(size), cropOrigin.x.isFinite, cropOrigin.y.isFinite else { return }
        if imageSize != size { imageSize = size }
        if self.cropOrigin != cropOrigin { self.cropOrigin = cropOrigin }
        recalculate()
    }

    func updateLayout(viewportSize: CGSize, backingScale: CGFloat) {
        guard Self.valid(viewportSize), backingScale.isFinite, backingScale > 0 else { return }
        if self.viewportSize != viewportSize { self.viewportSize = viewportSize }
        if self.backingScale != backingScale { self.backingScale = backingScale }
        recalculate()
    }

    func select(_ mode: ZoomMode) {
        self.mode = mode
        recalculate()
    }

    func userMagnified(to value: CGFloat) {
        guard value.isFinite, value > 0 else { return }
        if mode != .manual { mode = .manual }
        if magnification != value { magnification = value }
    }

    func originalPoint(fromCanvas point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + cropOrigin.x, y: point.y + cropOrigin.y)
    }

    private func recalculate() {
        guard Self.valid(imageSize), Self.valid(viewportSize) else { return }
        let widthFit = viewportSize.width / imageSize.width
        let heightFit = viewportSize.height / imageSize.height
        guard widthFit.isFinite, widthFit > 0, heightFit.isFinite, heightFit > 0 else { return }
        let value: CGFloat
        switch mode {
        case .fitAll: value = min(widthFit, heightFit)
        case .fitWidth: value = widthFit
        case .actualPixels: value = 1 / backingScale
        case .manual: return
        }
        if value.isFinite, value > 0, value != magnification { magnification = value }
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

@MainActor
struct EditorCanvas: NSViewRepresentable {
    let image: CGImage?
    let cropOrigin: CGPoint
    let viewport: EditorViewport
    var interaction: EditorInteraction? = nil

    func makeNSView(context: Context) -> EditorCanvasScrollView {
        let view = EditorCanvasScrollView(viewport: viewport)
        view.setAccessibilityIdentifier("editor-viewport")
        view.update(image: image, cropOrigin: cropOrigin, viewport: viewport)
        view.imageView.setAccessibilityElement(true)
        view.imageView.setAccessibilityRole(.image)
        view.imageView.setAccessibilityIdentifier("editor-canvas")
        view.imageView.setAccessibilityLabel("編集キャンバス")
        view.imageView.interaction = interaction
        view.imageView.cropOrigin = cropOrigin
        view.imageView.needsDisplay = true
        return view
    }

    func updateNSView(_ view: EditorCanvasScrollView, context: Context) {
        // Reading the observable scale here makes toolbar changes update the native view.
        _ = viewport.magnification
        view.update(image: image, cropOrigin: cropOrigin, viewport: viewport)
        view.imageView.interaction = interaction
        view.imageView.cropOrigin = cropOrigin
        view.imageView.needsDisplay = true
    }

    static func dismantleNSView(_ view: EditorCanvasScrollView, coordinator: ()) {
        view.detach()
    }
}

/// Displays only the already flattened preview. One document unit is one preview pixel.
@MainActor
final class EditorCanvasImageView: NSView {
    private(set) var image: CGImage?
    private(set) var previewImage: NSImage?
    weak var interaction: EditorInteraction?
    var cropOrigin: CGPoint = .zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x + cropOrigin.x, y: p.y + cropOrigin.y)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        interaction?.begin(point(event), shift: event.modifierFlags.contains(.shift))
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { interaction?.drag(point(event)); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        interaction?.end(point(event)); needsDisplay = true
    }


    func update(_ image: CGImage?) {
        if let image, let current = self.image, image === current { return }
        if image == nil, self.image == nil { return }
        self.image = image
        if let image {
            let size = CGSize(width: image.width, height: image.height)
            previewImage = NSImage(cgImage: image, size: size)
            setFrameSize(size)
        } else {
            previewImage = nil
            setFrameSize(.zero)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let previewImage else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.imageInterpolation = .none
        previewImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                          respectFlipped: true, hints: nil)
        guard let interaction else { return }
        NSColor.controlAccentColor.setStroke()
        if let b = interaction.pendingBounds, interaction.selectsRangeFirst || interaction.tool == .crop || interaction.tool == .select {
            let path = NSBezierPath(rect: NSRect(x: b.x - cropOrigin.x, y: b.y - cropOrigin.y,
                                                width: b.width, height: b.height))
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.lineWidth = 1
            path.stroke()
        }
        for object in interaction.session.draft.objects where interaction.selected.contains(object.id) {
            let b = object.bounds
            let rect = NSRect(x: b.x - cropOrigin.x, y: b.y - cropOrigin.y, width: b.width, height: b.height)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.stroke()
            NSColor.controlAccentColor.setFill()
            NSBezierPath(rect: NSRect(x: rect.maxX - 3, y: rect.maxY - 3, width: 6, height: 6)).fill()
        }
    }
}

@MainActor
final class EditorCanvasScrollView: NSScrollView {
    let imageView = EditorCanvasImageView(frame: .zero)
    private var viewport: EditorViewport
    private var cropOrigin: CGPoint = .zero
    private var scheduled = false
    private var detached = false
    private var applying = false
    private var positionedInitially = false
    private var magnificationObservation: NSKeyValueObservation?

    init(viewport: EditorViewport) {
        self.viewport = viewport
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = false
        allowsMagnification = true
        automaticallyAdjustsContentInsets = false
        contentView.automaticallyAdjustsContentInsets = false
        documentView = imageView
        // AppKit magnification mutations and their KVO delivery occur on the main thread.
        // Observe every native change, including animation/bounce after the gesture call returns.
        magnificationObservation = observe(\.magnification, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.recordNativeMagnification() }
        }
    }

    required init?(coder: NSCoder) { return nil }

    func update(image: CGImage?, cropOrigin: CGPoint, viewport: EditorViewport) {
        guard !detached else { return }
        self.viewport = viewport
        self.cropOrigin = cropOrigin
        imageView.update(image)
        scheduleSynchronization()
    }

    override func layout() {
        super.layout()
        scheduleSynchronization()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleSynchronization()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleSynchronization()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        recordNativeMagnification()
    }

    override func smartMagnify(with event: NSEvent) {
        super.smartMagnify(with: event)
        recordNativeMagnification()
    }

    /// Called after native gesture handling; unlike programmatic fits this selects manual mode.
    func recordNativeMagnification() {
        guard !detached, !applying else { return }
        viewport.userMagnified(to: magnification)
        // Avoid changing clip geometry inside AppKit's own magnification setter/KVO delivery.
        scheduleSynchronization()
    }

    func originalPoint(from point: CGPoint, in view: NSView) -> CGPoint {
        viewport.originalPoint(fromCanvas: imageView.convert(point, from: view))
    }

    func detach() {
        detached = true
        magnificationObservation?.invalidate()
        magnificationObservation = nil
        // A pending weak layout callback becomes inert; no global observers are removed.
    }

    private func scheduleSynchronization() {
        guard !detached, !scheduled, !applying else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard !self.detached else { return }
            self.synchronize()
        }
    }

    private func synchronize() {
        guard let image = imageView.image else {
            contentView.contentInsets = NSEdgeInsetsZero
            return
        }
        // Frame is measured in scroll-view points, unaffected by magnified bounds or insets.
        let available = contentView.frame.size
        let scale = window?.backingScaleFactor ?? 1
        viewport.updateImage(size: CGSize(width: image.width, height: image.height), cropOrigin: cropOrigin)
        viewport.updateLayout(viewportSize: available, backingScale: scale)
        guard available.width > 0, available.height > 0 else { return }
        if viewport.mode == .manual {
            // Manual scale and pinch anchor belong to AppKit, including transient overshoot.
            // Never restore an earlier reported model value or expand limits for a bounce.
            viewport.userMagnified(to: magnification)
            centerSmallImage()
            return
        }
        let candidates = [viewport.magnification, available.width / CGFloat(image.width),
                          min(available.width / CGFloat(image.width), available.height / CGFloat(image.height)),
                          1 / scale].filter { $0.isFinite && $0 > 0 }
        guard let smallest = candidates.min(), let largest = candidates.max() else { return }
        applying = true
        defer { applying = false }
        // Expand, never truncate, native limits before applying a fit or actual-pixel scale.
        if maxMagnification < largest { maxMagnification = largest }
        if minMagnification > smallest { minMagnification = smallest }
        if magnification != viewport.magnification {
            let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
            setMagnification(viewport.magnification, centeredAt: center)
        }
        centerSmallImage()
        if !positionedInitially {
            positionedInitially = true
            // Start at the top-left within the centering insets, never outside them.
            scrollClamped(to: .zero)
        }
    }

    private func centerSmallImage() {
        let size = imageView.frame.size
        let visible = contentView.frame.size
        let x = max(0, (visible.width - size.width * magnification) / 2)
        let y = max(0, (visible.height - size.height * magnification) / 2)
        let old = contentView.contentInsets
        guard old.left != x || old.right != x || old.top != y || old.bottom != y else { return }
        contentView.contentInsets = NSEdgeInsets(top: y, left: x, bottom: y, right: x)
        scrollClamped(to: contentView.bounds.origin)
    }

    private func scrollClamped(to origin: CGPoint) {
        let constrained = contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size))
        contentView.scroll(to: constrained.origin)
        reflectScrolledClipView(contentView)
    }
}
