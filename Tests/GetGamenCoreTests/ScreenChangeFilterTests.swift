import AppKit
import XCTest
@testable import GetGamenCore

final class ScreenChangeFilterTests: XCTestCase {
    private enum ReadError: Error { case unavailable }

    private func screen(runtimeID: UInt32 = 1,
                        frame: RegionRect = RegionRect(x: 0, y: 0, width: 800, height: 600),
                        backingScaleFactor: Double = 2, rotation: Double = 0,
                        backingWidth: Int = 1600, backingHeight: Int = 1200,
                        mirrorRuntimeID: UInt32 = 0, inMirrorSet: Bool = false) -> ScreenFacts {
        ScreenFacts(runtimeID: runtimeID, id: String(runtimeID), frame: frame,
                    backingScaleFactor: backingScaleFactor, rotation: rotation,
                    backingWidth: backingWidth, backingHeight: backingHeight,
                    mirrorRuntimeID: mirrorRuntimeID, inMirrorSet: inMirrorSet)
    }

    @MainActor
    func testUnchangedFactsIgnoreRepeatedNotifications() {
        let facts = [screen()]
        let filter = ScreenChangeFilter { facts }
        XCTAssertFalse(filter.changed())
        XCTAssertFalse(filter.changed())
    }

    @MainActor
    func testRegionPanelsOnlyEmitTopologyChangedWhenFactsChange() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty)
        var facts = try currentScreenFacts()
        let displays = facts.map {
            RegionDisplay(id: $0.id, runtimeID: $0.runtimeID, frame: $0.frame,
                          scale: $0.backingScaleFactor, rotation: $0.rotation,
                          backingWidth: $0.backingWidth, backingHeight: $0.backingHeight,
                          mirrorSourceID: nil)
        }
        var events: [RegionSelectionEvent] = []
        let panels = try RegionSelectionPresentation.presentNative(
            displays: displays, shortcut: nil, screenFacts: { facts },
            action: { events.append($0) })
        defer {
            panels.hide()
            panels.close()
        }

        let notification = NSApplication.didChangeScreenParametersNotification
        NotificationCenter.default.post(name: notification, object: nil)
        NotificationCenter.default.post(name: notification, object: nil)
        XCTAssertTrue(events.isEmpty)

        facts.append(screen(runtimeID: .max))
        NotificationCenter.default.post(name: notification, object: nil)
        XCTAssertEqual(events.count, 1)
        guard case .topologyChanged = try XCTUnwrap(events.first) else {
            return XCTFail("画面情報の変更で topologyChanged が通知されること")
        }
    }

    @MainActor
    func testWindowPickerOnlyCancelsWhenFactsChange() throws {
        var facts = [screen()]
        var events: [WindowPickerEvent] = []
        let session = try DirectWindowPickerSession(
            exclusions: [], screenFacts: { facts }, receive: { events.append($0) })
        defer { session.close() }

        let notification = NSApplication.didChangeScreenParametersNotification
        NotificationCenter.default.post(name: notification, object: nil)
        NotificationCenter.default.post(name: notification, object: nil)
        XCTAssertTrue(events.isEmpty)

        facts = [screen(backingScaleFactor: 1)]
        NotificationCenter.default.post(name: notification, object: nil)
        // The cancellation closes the session; later notifications must not cancel again.
        NotificationCenter.default.post(name: notification, object: nil)
        XCTAssertEqual(events.count, 1)
        guard case .cancelled = try XCTUnwrap(events.first) else {
            return XCTFail("画面情報の変更で cancelled が一度だけ通知されること")
        }
    }

    @MainActor
    func testGeometryChangesAreDetected() {
        let initial = [screen()]
        let changes: [(String, [ScreenFacts])] = [
            ("frame", [screen(frame: RegionRect(x: 10, y: 0, width: 800, height: 600))]),
            ("screen added", [screen(), screen(runtimeID: 2)]),
            ("scale", [screen(backingScaleFactor: 1)]),
            ("rotation", [screen(rotation: 90)]),
            ("backing width", [screen(backingWidth: 800)]),
            ("backing height", [screen(backingHeight: 600)]),
            ("mirror source", [screen(mirrorRuntimeID: 2)]),
            ("mirror membership", [screen(inMirrorSet: true)])
        ]
        for (name, changedFacts) in changes {
            var current = initial
            let filter = ScreenChangeFilter { current }
            XCTAssertFalse(filter.changed(), name)
            current = changedFacts
            XCTAssertTrue(filter.changed(), name)
            XCTAssertTrue(filter.changed(), name)
        }
    }

    @MainActor
    func testLaterReadFailureIsAChange() {
        let facts = [screen()]
        var fails = false
        let filter = ScreenChangeFilter {
            if fails { throw ReadError.unavailable }
            return facts
        }
        fails = true
        XCTAssertTrue(filter.changed())
    }

    @MainActor
    func testInitialReadFailureIsAChangeEvenAfterRecovery() {
        let facts = [screen()]
        var fails = true
        let filter = ScreenChangeFilter {
            if fails { throw ReadError.unavailable }
            return facts
        }
        fails = false
        XCTAssertTrue(filter.changed())
    }
}
