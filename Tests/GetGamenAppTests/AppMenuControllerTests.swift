import AppKit
import XCTest
@testable import GetGamen

@MainActor
final class AppMenuControllerTests: XCTestCase {
    func testConstructionBuildsMainMenuWithoutInstallationSideEffects() throws {
        let f = try Fixture()
        XCTAssertFalse(f.controller.isInstalled)
        XCTAssertTrue(f.controller.statusMenu.items.isEmpty)
        XCTAssertEqual(f.mainCommands(), Set(AppCommand.available))
        XCTAssertTrue(f.allMainCommandItems().allSatisfy { $0.keyEquivalent.isEmpty })
    }

    func testMenusExcludeScrollCommands() throws {
        let f = try Fixture()
        f.open()
        let mainItems = f.controller.mainMenu.items.flatMap { $0.submenu?.items ?? [] }
        for command in [AppCommand.captureScroll, .scrollPause, .scrollFinish] {
            XCTAssertFalse(mainItems.contains { $0.title == command.title }, command.title)
            XCTAssertFalse(f.controller.statusMenu.items.contains { $0.title == command.title }, command.title)
        }
        f.close()
    }

    func testStatusActionThenCloseDeliversOnceOnNextTurn() async throws {
        let f = try Fixture()
        f.open()
        f.invoke(.captureRegion)
        f.invoke(.captureRegion)
        XCTAssertTrue(f.actions.isEmpty)
        f.close()
        XCTAssertTrue(f.actions.isEmpty)
        f.drain()
        XCTAssertEqual(f.actions, [.captureRegion])
    }

    func testStatusCloseThenActionDeliversOnce() async throws {
        let f = try Fixture()
        f.open()
        let item = try f.item(.captureWindow)
        f.close()
        XCTAssertTrue(f.actions.isEmpty)
        f.perform(item)
        f.perform(item)
        f.drain()
        XCTAssertEqual(f.actions, [.captureWindow])
    }

    func testCancelledCloseDoesNotDispatchAndNextOpeningInvalidatesOldTarget() async throws {
        let f = try Fixture()
        f.open()
        let stale = try f.item(.chooser)
        f.close()
        f.drain()
        XCTAssertTrue(f.actions.isEmpty)
        f.open()
        f.perform(stale)
        f.close()
        f.drain()
        XCTAssertTrue(f.actions.isEmpty)
    }

    func testAcceptedCommandWaitsAcrossReopenUntilTrackingEnds() async throws {
        let f = try Fixture()
        f.open()
        f.controller.acceptRoutedCommand(.quit)
        f.close()
        f.open()
        f.drain()
        XCTAssertTrue(f.actions.isEmpty)
        f.close()
        f.drain()
        XCTAssertEqual(f.actions, [.quit])
    }

    func testRapidReopenDoesNotStrandAlreadyAcceptedCommand() async throws {
        let f = try Fixture()
        f.open()
        f.invoke(.captureRegion)
        f.close()
        f.open()
        f.close()
        XCTAssertTrue(f.actions.isEmpty)
        f.drain()
        XCTAssertEqual(f.actions, [.captureRegion])
    }

    func testDeliveryRechecksEnabledState() async throws {
        let f = try Fixture()
        f.open()
        f.invoke(.capturePrevious)
        f.enabled.remove(.capturePrevious)
        f.close()
        f.drain()
        XCTAssertTrue(f.actions.isEmpty)
    }

    func testStatusMenuValidationReflectsLiveEnabledState() throws {
        let f = try Fixture()
        f.open()
        let item = try f.item(.capturePrevious)
        f.controller.statusMenu.update()
        XCTAssertTrue(item.isEnabled)
        f.enabled.remove(.capturePrevious)
        f.controller.statusMenu.update()
        XCTAssertFalse(item.isEnabled)
        f.enabled.insert(.capturePrevious)
        f.controller.statusMenu.update()
        XCTAssertTrue(item.isEnabled)
        f.close()
    }

    func testDisabledAtActivationCannotExecuteAfterBeingReenabled() async throws {
        let f = try Fixture()
        f.open()
        let item = try f.item(.capturePrevious)
        f.enabled.remove(.capturePrevious)
        f.perform(item)
        f.enabled.insert(.capturePrevious)
        f.close()
        f.drain()
        XCTAssertTrue(f.actions.isEmpty)
    }

    func testRoutedLocalAndGlobalCommandsWaitDuringTrackingAndKeepFIFOOrder() async throws {
        let f = try Fixture()
        f.open()
        f.controller.acceptRoutedCommand(.quit)
        f.controller.acceptRoutedCommand(.captureWindow)
        XCTAssertTrue(f.actions.isEmpty)
        f.close()
        f.drain()
        XCTAssertEqual(f.actions, [.quit, .captureWindow])
    }

    func testUninstallInvalidatesQueuedTurnAndOldTargets() async throws {
        let f = try Fixture()
        f.open()
        let stale = try f.item(.chooser)
        f.controller.acceptRoutedCommand(.quit)
        f.close()
        f.controller.uninstall()
        f.perform(stale)
        f.drain()
        XCTAssertTrue(f.actions.isEmpty)
        XCTAssertFalse(f.controller.isInstalled)
    }

    func testNativeInstallUninstallRestoresIdentityAndPreservesInterveningOwner() throws {
        let app = NSApplication.shared, prior = app.mainMenu
        defer { app.mainMenu = prior }
        let f = try Fixture()
        f.controller.install(in: app)
        XCTAssertTrue(app.mainMenu === f.controller.mainMenu)
        let first = try XCTUnwrap(f.controller.statusItem)
        f.controller.install(in: app)
        XCTAssertTrue(f.controller.statusItem === first)
        f.controller.uninstall()
        XCTAssertTrue(app.mainMenu === prior)
        XCTAssertNil(f.controller.statusItem)
        f.controller.uninstall()
        f.controller.install(in: app)
        XCTAssertFalse(f.controller.statusItem === first)
        let replacement = NSMenu(title: "Other owner")
        app.mainMenu = replacement
        f.controller.uninstall()
        XCTAssertTrue(app.mainMenu === replacement)
    }

    func testStatusInventoryUsesSameLabelsAndNoCharacterEquivalents() throws {
        let f = try Fixture()
        f.open()
        XCTAssertEqual(Set(f.controller.statusMenu.items.map(\.title)), Set(AppCommand.available.map(\.title)))
        XCTAssertTrue(f.controller.statusMenu.items.allSatisfy { $0.keyEquivalent.isEmpty })
        for command in AppCommand.available {
            XCTAssertEqual(try f.item(command).title, command.title)
        }
        f.close()
    }


}

@MainActor
private final class Fixture {
    var scheduled: [@MainActor () -> Void] = []
    var actions: [AppCommand] = []
    var enabled = Set(AppCommand.allCases)
    private let link: WeakMenuLink
    let routing: AppCommandRouting
    let controller: AppMenuController

    init() throws {
        let link = WeakMenuLink()
        self.link = link
        routing = try AppCommandRouting(bindings: AppCommand.defaultBindings,
                                        isEnabled: { [weak link] command in link?.fixture?.enabled.contains(command) ?? false },
                                        perform: { [weak link] command in link?.fixture?.controller.acceptRoutedCommand(command) })
        controller = AppMenuController(routing: routing, deferDelivery: { [weak link] action in link?.fixture?.scheduled.append(action) }) { [weak link] command in
            link?.fixture?.actions.append(command)
        }
        link.fixture = self
    }

    func drain() {
        var count = 0
        while !scheduled.isEmpty, count < 100 { count += 1; scheduled.removeFirst()() }
        XCTAssertTrue(scheduled.isEmpty)
    }
    func open() { controller.menuWillOpen(controller.statusMenu) }
    func close() { controller.menuDidClose(controller.statusMenu) }

    func item(_ command: AppCommand) throws -> NSMenuItem {
        try XCTUnwrap(controller.statusMenu.items.first { $0.title == command.title })
    }

    func invoke(_ command: AppCommand) {
        guard let item = try? item(command) else { return }
        perform(item)
    }

    func perform(_ item: NSMenuItem) {
        guard let target = item.target, let action = item.action else { return }
        _ = target.perform(action, with: item)
    }

    func allMainCommandItems() -> [AppCommandMenuItem] {
        controller.mainMenu.items.flatMap { $0.submenu?.items ?? [] }.compactMap { $0 as? AppCommandMenuItem }
    }

    func mainCommands() -> Set<AppCommand> { Set(allMainCommandItems().map(\.command)) }
}

@MainActor
private final class WeakMenuLink {
    weak var fixture: Fixture?
}
