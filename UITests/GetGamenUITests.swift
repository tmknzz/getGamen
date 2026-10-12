import XCTest
import AppKit
import Darwin

final class GetGamenUITests: XCTestCase {
    private var testRoot: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        testRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("getGamen-ui-\(UUID())")
    }
    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }
    private func application() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = ["GETGAMEN_UI_TEST_ROOT": testRoot.path]
        return app
    }

    func testLaunchCaptureChooserAndNativeSettingsRoute() {
        let app = application()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let chooser = app.windows["getGamen — 撮影"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        XCTAssertTrue(chooser.buttons["ウインドウ"].exists)
        XCTAssertTrue(chooser.buttons["範囲"].exists)
        XCTAssertTrue(chooser.buttons["前と同じ範囲"].exists)
        let applicationMenu = app.menuBars.menuBarItems["getGamen"]
        applicationMenu.click()
        XCTAssertTrue(applicationMenu.menus.menuItems["getGamenについて"].exists)
        applicationMenu.menus.menuItems["設定…"].click()
        let settings = app.windows["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons["保存先フォルダを選ぶ…"].exists)
        settings.buttons["保存先フォルダを選ぶ…"].click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5))
        app.dialogs.firstMatch.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settings.exists)
        settings.toolbars.buttons["ショートカット"].click()
        settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -1200)
        let recorder = settings.buttons["shortcut-settings"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 3))
        recorder.click()
        recorder.typeKey("k", modifierFlags: [.command, .control])
        XCTAssertFalse(recorder.title.contains("キーを入力"))
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(chooser.exists)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
        app.activate()
        chooser.typeKey("k", modifierFlags: [.command, .control])
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        app.terminate()
    }

    func testDockReopenShowsChooserWithSettingsVisible() throws {
        let app = application()
        app.launch()
        let chooser = app.windows["getGamen — 撮影"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        chooser.typeKey("w", modifierFlags: .command)
        let menu = app.menuBars.menuBarItems["getGamen"]
        menu.click()
        menu.menus.menuItems["設定…"].click()
        XCTAssertTrue(app.windows["settings"].waitForExistence(timeout: 5))
        let running = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.tmknzz.getGamen" && $0.bundleURL?.path.contains("/Debug/") == true
        })
        let url = try XCTUnwrap(running.bundleURL)
        // LaunchServices sends the same reopen event as clicking the Dock icon.
        let reopened = expectation(description: "Application reopened")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            XCTAssertNil(error)
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 10)
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        XCTAssertTrue(chooser.buttons["ウインドウ"].isHittable)
        XCTAssertTrue(chooser.buttons["範囲"].isHittable)
        XCTAssertTrue(chooser.buttons["前と同じ範囲"].isHittable)
    }

    func testColdLaunchStartsRememberedModeWithoutChooserButton() throws {
        let app = application()
        app.launch()
        let chooser = app.windows["getGamen — 撮影"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        try XCTSkipIf(!chooser.buttons["スクロール撮影"].exists, "スクロール撮影は一時的に非表示")
        chooser.buttons["スクロール撮影"].click()
        XCTAssertTrue(app.windows["getGamen — スクロール撮影"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment["GETGAMEN_UI_PRESERVE_DEFAULTS"] = "1"
        app.launch()
        // Launch shares the Dock path: the chooser stays visible while the saved mode starts.
        XCTAssertTrue(app.windows["getGamen — スクロール撮影"].waitForExistence(timeout: 5))
    }

    func testNativeFieldMarkedTextSheetAndModalKeepKeyboardOwnership() {
        let app = application(); app.launchArguments = ["--ui-input-probe"]; app.launch()
        let probe = app.windows["Native input probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let field = probe.textFields["native-input"]
        field.click(); field.typeText("sample")
        XCTAssertEqual(field.value as? String, "sample")
        XCTAssertFalse(app.windows["settings"].exists, "Plain S is bound to settings but belongs to this field")
        field.typeKey("a", modifierFlags: .command); field.typeText("replacement")
        XCTAssertEqual(field.value as? String, "replacement")
        probe.buttons["Marked text"].click()
        probe.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(probe.exists, "Marked text must prevent application quit")
        probe.typeKey(.escape, modifierFlags: [])
        probe.buttons["Sheet"].click()
        XCTAssertTrue(probe.sheets.firstMatch.waitForExistence(timeout: 3))
        probe.sheets.firstMatch.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(probe.sheets.firstMatch.exists)
        probe.sheets.firstMatch.buttons["Done"].click()
        probe.buttons["Modal"].click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 3))
        app.dialogs.firstMatch.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.dialogs.firstMatch.exists)
        app.dialogs.buttons["OK"].click()
    }

    func testImportedImageEditsPersistAfterQuitAndRelaunchDiscardsThem() throws {
        let input = testRoot.appendingPathComponent("source.png")
        let app = application()
        app.launchEnvironment["GETGAMEN_UI_CREATE_FIXTURE"] = "1"
        app.launchEnvironment["GETGAMEN_UI_TEST_IMAGE"] = input.path
        app.launch()
        let canvas = app.images["editor-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        let original = try Data(contentsOf: input)
        let editMenu = app.menuBars.menuBarItems["編集"]
        editMenu.click()
        let maskItem = editMenu.menus.menuItems["マスク"]
        XCTAssertTrue(maskItem.waitForExistence(timeout: 3))
        maskItem.click()
        canvas.click()
        XCTAssertEqual(app.buttons["editor-tool-rectangle.fill"].value as? String, "選択中")
        let viewport = app.scrollViews["editor-viewport"]
        let visible = canvas.frame.intersection(viewport.frame)
        XCTAssertGreaterThan(visible.width, 20)
        XCTAssertGreaterThan(visible.height, 20)
        let origin = viewport.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: visible.minX - viewport.frame.minX + visible.width * 0.4, dy: visible.minY - viewport.frame.minY + visible.height * 0.4))
        let end = origin.withOffset(CGVector(dx: visible.minX - viewport.frame.minX + visible.width * 0.6, dy: visible.minY - viewport.frame.minY + visible.height * 0.6))
        start.click(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["編集データ保存済み"].waitForExistence(timeout: 5))
        app.terminate()
        XCTAssertEqual(try Data(contentsOf: input), original)
        let documents = testRoot.appendingPathComponent("documents")
        let folders = try FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        let json = try Data(contentsOf: folders[0].appendingPathComponent("document.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let edits = try XCTUnwrap(document["edits"] as? [String: Any])
        XCTAssertEqual((edits["objects"] as? [Any])?.count, 1)
        let relaunched = application()
        relaunched.launch()
        XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 10))
        let remaining = try FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining, [], "Launch discards documents an earlier run left behind")
    }
}
