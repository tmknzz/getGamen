import AppKit
import Carbon
import XCTest
@testable import GetGamenCore

/// Hidden native windows and constructed events test adapters, not physical input or screen capture.
final class RegionSelectionViewTests: XCTestCase {
    @MainActor
    func testControlsFollowSelectionAndRemainUsableForTinyRegions() {
        let (panel, view) = makePanel(frame: CGRect(x: 0, y: 0, width: 800, height: 600)) { _ in }
        defer { panel.close() }
        for origin in [CGPoint(x: 40, y: 60), CGPoint(x: 300, y: 250)] {
            view.update(rect: RegionRect(x: origin.x, y: origin.y, width: 300, height: 180),
                        pixelSize: PixelSize(width: 600, height: 360))
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(view.selectionRect!.contains(view.captureButton.frame))
            XCTAssertTrue(view.selectionRect!.contains(view.dimensionLabel.frame))
            XCTAssertEqual(view.captureButton.frame.size, CGSize(width: 52, height: 44))
            XCTAssertEqual(view.captureButton.frame.midX, view.selectionRect!.midX, accuracy: 0.01)
            XCTAssertEqual(view.dimensionLabel.frame.midX, view.selectionRect!.midX, accuracy: 0.01)
            XCTAssertLessThan(view.dimensionLabel.frame.maxY, view.captureButton.frame.minY)
            XCTAssertEqual(view.captureButton.frame.union(view.dimensionLabel.frame).midY,
                           view.selectionRect!.midY, accuracy: 0.01)
            XCTAssertEqual(view.captureButton.contentTintColor, .white)
            XCTAssertFalse(view.captureButton.isBordered)
        }
        view.update(rect: RegionRect(x: 400, y: 300, width: 5, height: 5),
                    pixelSize: PixelSize(width: 10, height: 10))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.captureButton.isHidden)
        XCTAssertTrue(view.bounds.contains(view.captureButton.frame))
        XCTAssertTrue(view.bounds.contains(view.dimensionLabel.frame))
        XCTAssertFalse(view.captureButton.frame.intersects(view.selectionRect!))
    }

    @MainActor
    func testReleasedSelectionCanMoveResizeAndCopyOnlyAfterConfirmation() throws {
        var events: [RegionSelectionEvent] = []
        let adjustment = RegionSelectionAdjustment { events.append($0) }
        adjustment.receive(.began(CGPoint(x: 10, y: 20)))
        adjustment.receive(.ended(CGPoint(x: 110, y: 100)))
        XCTAssertEqual(adjustment.rect, CGRect(x: 10, y: 20, width: 100, height: 80))
        XCTAssertFalse(events.contains { if case .ended = $0 { return true }; return false })
        adjustment.receive(.began(CGPoint(x: 50, y: 50)))
        adjustment.receive(.ended(CGPoint(x: 70, y: 60)))
        XCTAssertEqual(adjustment.rect, CGRect(x: 30, y: 30, width: 100, height: 80))
        adjustment.receive(.began(CGPoint(x: 130, y: 110)))
        adjustment.receive(.ended(CGPoint(x: 160, y: 130)))
        XCTAssertEqual(adjustment.rect, CGRect(x: 30, y: 30, width: 130, height: 100))
        events.removeAll()
        adjustment.confirm(copy: true)
        XCTAssertEqual(events.count, 2)
        guard case .copyRequested = events[0], case .ended(let point) = events[1] else {
            return XCTFail("Copy intent must precede final capture")
        }
        XCTAssertEqual(point, CGPoint(x: 160, y: 130))
    }

    @MainActor
    func testPresetSelectionConfirmsCaptureAndCopyWithoutDragging() throws {
        var events: [RegionSelectionEvent] = []
        let adjustment = RegionSelectionAdjustment { events.append($0) }
        adjustment.preset(CGRect(x: -90, y: 70, width: 20, height: 10))
        XCTAssertTrue(events.isEmpty)
        adjustment.confirm()
        XCTAssertEqual(events.count, 1)
        guard case .ended(let point) = try XCTUnwrap(events.first) else { return XCTFail("Expected ended") }
        XCTAssertEqual(point, CGPoint(x: -70, y: 80))
        events.removeAll()
        let copyAdjustment = RegionSelectionAdjustment { events.append($0) }
        copyAdjustment.preset(CGRect(x: -90, y: 70, width: 20, height: 10))
        XCTAssertTrue(events.isEmpty)
        copyAdjustment.confirm(copy: true)
        XCTAssertEqual(events.count, 2)
        guard events.count == 2 else { return }
        guard case .copyRequested = events[0], case .ended(let copyPoint) = events[1] else {
            return XCTFail("Copy intent must precede final capture")
        }
        XCTAssertEqual(copyPoint, CGPoint(x: -70, y: 80))
    }

    @MainActor
    func testCommandCConfirmsCopyAndReturnConfirmsCapture() throws {
        let (panel, view) = makePanel(frame: CGRect(x: 0, y: 0, width: 400, height: 300)) { _ in }
        defer { panel.close() }
        var confirmations: [Bool] = []
        view.onConfirm = { confirmations.append($0) }
        view.update(rect: RegionRect(x: 20, y: 20, width: 100, height: 100),
                    pixelSize: PixelSize(width: 100, height: 100))
        XCTAssertTrue(view.performKeyEquivalent(with: try key(window: panel, code: 8, flags: .command, characters: "c")))
        view.keyDown(with: try key(window: panel, code: 36, flags: [], characters: "\r"))
        XCTAssertEqual(confirmations, [true, false])
    }

    @MainActor
    func testAllDragDirectionsUseGlobalPointsWithoutClamping() throws {
        var events: [RegionSelectionEvent] = []
        let (panel, view) = makePanel(frame: CGRect(x: -500, y: -250, width: 320, height: 200)) { events.append($0) }
        defer { panel.close() }
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame, CGRect(x: -500, y: -250, width: 320, height: 200))
        for endpoint in [CGPoint(x: 500, y: 400), CGPoint(x: -100, y: 400),
                         CGPoint(x: 500, y: -100), CGPoint(x: -100, y: -100)] {
            events.removeAll()
            view.mouseDown(with: try mouse(.leftMouseDown, window: panel, point: CGPoint(x: 20, y: 30)))
            view.mouseDragged(with: try mouse(.leftMouseDragged, window: panel, point: endpoint))
            view.mouseUp(with: try mouse(.leftMouseUp, window: panel, point: endpoint))
            XCTAssertEqual(events.count, 3)
            guard events.count == 3 else { continue }
            if case .began(let point) = events[0] { XCTAssertEqual(point, CGPoint(x: -480, y: -220)) }
            else { XCTFail("Expected began") }
            let expected = CGPoint(x: endpoint.x - 500, y: endpoint.y - 250)
            if case .changed(let point) = events[1] { XCTAssertEqual(point, expected) }
            else { XCTFail("Expected changed") }
            if case .ended(let point) = events[2] { XCTAssertEqual(point, expected) }
            else { XCTFail("Expected ended") }
        }
        XCTAssertFalse(panel.isVisible, "Adapter tests must not order a native window onscreen")
    }

    @MainActor
    func testConversionUsesActualEventWindowAndRejectsMissingWindow() throws {
        var events: [RegionSelectionEvent] = []
        let (first, view) = makePanel(frame: CGRect(x: -500, y: -250, width: 320, height: 200)) { events.append($0) }
        let (second, _) = makePanel(frame: CGRect(x: 100, y: 300, width: 320, height: 200)) { _ in }
        defer { first.close(); second.close() }
        view.mouseDragged(with: try mouse(.leftMouseDragged, window: second, point: CGPoint(x: -80, y: 450)))
        guard case .changed(let point) = try XCTUnwrap(events.first) else { return XCTFail("Expected changed") }
        XCTAssertEqual(point, CGPoint(x: 20, y: 750))
        events.removeAll()
        let missing = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        XCTAssertNil(missing.window)
        view.mouseUp(with: missing)
        guard case .failed(let error) = try XCTUnwrap(events.first) else { return XCTFail("Expected failure") }
        XCTAssertEqual(error as? RegionSelectionError, .invalidSelection)
        events.removeAll()
        view.interactionEnabled = false
        view.mouseDragged(with: try mouse(.leftMouseDragged, window: first, point: .zero))
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testSignedPreviewIntersectsEachScreenAndDisplaysSuppliedPixelDimensions() {
        let (first, a) = makePanel(frame: CGRect(x: -500, y: -250, width: 320, height: 200)) { _ in }
        let (second, b) = makePanel(frame: CGRect(x: -180, y: -250, width: 320, height: 200)) { _ in }
        defer { first.close(); second.close() }
        for rect in [RegionRect(x: -400, y: -200, width: 500, height: 100),
                     RegionRect(x: 100, y: -100, width: -500, height: -100)] {
            for view in [a, b] {
                view.update(rect: rect, pixelSize: PixelSize(width: 1000, height: 200))
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.dimensionLabel.stringValue, "1000 × 200 px")
                XCTAssertFalse(view.dimensionLabel.isHidden)
                XCTAssertTrue(view.bounds.contains(view.dimensionLabel.frame))
                XCTAssertTrue(view.selectionRect!.contains(view.dimensionLabel.frame))
                XCTAssertTrue(view.selectionRect!.contains(view.captureButton.frame))
                XCTAssertFalse(view.dimensionLabel.frame.intersects(view.captureButton.frame))
                XCTAssertEqual(view.captureButton.title, "")
                XCTAssertNotNil(view.captureButton.image)
                XCTAssertTrue(view.bounds.contains(view.cancelButton.frame))
                XCTAssertFalse(view.dimensionLabel.frame.intersects(view.cancelButton.frame))
                XCTAssertEqual(view.cancelButton.keyEquivalent, "")
            }
            XCTAssertEqual(a.selectionRect, CGRect(x: 100, y: 50, width: 220, height: 100))
            XCTAssertEqual(b.selectionRect, CGRect(x: 0, y: 50, width: 280, height: 100))
        }
        a.update(rect: nil, pixelSize: nil)
        XCTAssertNil(a.selectionRect)
        XCTAssertTrue(a.dimensionLabel.isHidden)
        XCTAssertTrue(a.captureButton.isHidden)
        XCTAssertEqual(a.dimensionLabel.stringValue, "")
    }

    @MainActor
    func testConfiguredCancelWorksForCanvasAndButtonAcrossNativeEntryPathsOnce() throws {
        var cancellations = 0
        let shortcut = HotKeyShortcut(keyCode: 7, modifiers: UInt32(cmdKey | shiftKey))
        let (panel, view) = makePanel(frame: CGRect(x: 0, y: 0, width: 320, height: 200), shortcut: shortcut) {
            if case .cancelled = $0 { cancellations += 1 }
        }
        defer { panel.close() }
        for responder: NSResponder in [view, view.cancelButton] {
            XCTAssertTrue(panel.makeFirstResponder(responder))
            XCTAssertTrue(panel.firstResponder === responder)
            let before = cancellations
            let equivalent = try key(window: panel, code: 7, flags: [.command, .shift], characters: "X")
            XCTAssertTrue(panel.performKeyEquivalent(with: equivalent))
            panel.sendEvent(equivalent)
            panel.keyDown(with: equivalent)
            XCTAssertEqual(cancellations, before + 1, "One consumed event must not dispatch through multiple paths")
            panel.sendEvent(try key(window: panel, code: 7, flags: [.command, .shift], characters: "X"))
            panel.keyDown(with: try key(window: panel, code: 7, flags: [.command, .shift], characters: "X"))
            XCTAssertEqual(cancellations, before + 3)
            let escape = try key(window: panel, code: 53, flags: [], characters: "\u{1b}")
            XCTAssertTrue(panel.performKeyEquivalent(with: escape), "Consume legacy fallback without cancelling")
            panel.sendEvent(escape)
            panel.keyDown(with: escape)
            panel.cancelOperation(nil)
            XCTAssertEqual(cancellations, before + 3, "Rebound Escape must not implicitly cancel")
            panel.keyDown(with: try key(window: panel, code: 7, flags: [.command], characters: "x"))
            XCTAssertEqual(cancellations, before + 3, "Modifiers must match exactly")
        }
        let beforeButton = cancellations
        view.cancelButton.performClick(nil)
        XCTAssertEqual(cancellations, beforeButton + 1)
        panel.interactionEnabled = false
        panel.sendEvent(try key(window: panel, code: 7, flags: [.command, .shift], characters: "X"))
        XCTAssertEqual(cancellations, beforeButton + 1)
    }

    @MainActor
    func testSuppliedEscapeAndCancelButtonUseSameCommandWithoutStartingDrag() throws {
        var events: [RegionSelectionEvent] = []
        let (panel, view) = makePanel(frame: CGRect(x: 0, y: 0, width: 320, height: 200)) { events.append($0) }
        defer { panel.close() }
        panel.keyDown(with: try key(window: panel, code: 53, flags: [], characters: "\u{1b}"))
        XCTAssertEqual(events.count, 1)
        if case .cancelled? = events.first {} else { XCTFail("Supplied Escape did not cancel") }
        events.removeAll()
        view.layoutSubtreeIfNeeded()
        let point = CGPoint(x: view.cancelButton.frame.midX, y: view.cancelButton.frame.midY)
        view.mouseDown(with: try mouse(.leftMouseDown, window: panel, point: point))
        XCTAssertTrue(events.isEmpty)
        view.cancelButton.performClick(nil)
        XCTAssertEqual(events.count, 1)
        if case .cancelled? = events.first {} else { XCTFail("Button did not cancel") }
    }

    @MainActor
    func testOnlyFactuallyDeclaredMirrorsDeduplicate() throws {
        func display(_ id: String, _ runtime: UInt32, _ x: Double, mirror: String?) -> RegionDisplay {
            RegionDisplay(id: id, runtimeID: runtime, frame: RegionRect(x: x, y: 0, width: 100, height: 100),
                          scale: 1, rotation: 0, backingWidth: 100, backingHeight: 100, mirrorSourceID: mirror)
        }
        let source = display("source", 1, 0, mirror: "source")
        let follower = display("follower", 2, 0, mirror: "source")
        let other = display("other", 3, -100, mirror: nil)
        XCTAssertEqual(try RegionSelectionPresentation.canonicalDisplays([source, follower, other]).map(\.id), ["other", "source"])
        XCTAssertThrowsError(try RegionSelectionPresentation.canonicalDisplays([
            display("a", 1, 0, mirror: nil), display("b", 2, 0, mirror: nil)])) {
            XCTAssertEqual($0 as? RegionGeometryError, .ambiguousOverlap)
        }
        XCTAssertThrowsError(try RegionSelectionPresentation.canonicalDisplays([
            source, display("follower", 2, 100, mirror: "source")])) {
            XCTAssertEqual($0 as? RegionGeometryError, .invalidDisplayIdentity)
        }
    }

    @MainActor
    private func makePanel(frame: CGRect, shortcut: HotKeyShortcut = HotKeyShortcut(keyCode: 53, modifiers: 0),
                           action: @escaping @MainActor (RegionSelectionEvent) -> Void) -> (RegionSelectionPanel, RegionSelectionView) {
        _ = NSApplication.shared
        let panel = RegionSelectionPanel(frame: frame, cancelShortcut: shortcut) { action(.cancelled) }
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: frame.size), action: action)
        panel.contentView = view
        return (panel, view)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, window: NSWindow, point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func key(window: NSWindow, code: UInt16, flags: NSEvent.ModifierFlags, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code))
    }
}
