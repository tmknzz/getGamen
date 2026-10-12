import Darwin
import XCTest
import GetGamenCore

final class LaunchRoutingTests: XCTestCase {
    func testGUILaunchArgumentsStayOnGUIPath() {
        let cases: [[String]] = [
            [],
            ["-psn_0_1"],
            ["--smoke-output", "/tmp/smoke"],
            ["--ui-input-probe"],
            ["--ui-quit-smoke"],
            ["-AppleLanguages", "(en)"],
            ["-NSDocumentRevisionsDebugMode", "YES"],
            ["-ApplePersistenceIgnoreState", "YES"],
            ["-NSTreatUnknownArgumentsAsOpen", "NO"],
            ["-unknown"],
            ["-help"],
            ["-"]
        ]
        for arguments in cases {
            XCTAssertFalse(LaunchRouting.runsAutomation(arguments), "\(arguments)")
        }
    }

    func testAutomationLaunchArgumentsUseHelper() {
        let cases: [[String]] = [
            ["-h"],
            ["--help"],
            ["--version"],
            ["status"],
            ["mcp"],
            ["help"],
            ["--foo"],
            ["--"],
            ["/tmp/image.png"],
            ["image.png"],
            [""]
        ]
        for arguments in cases {
            XCTAssertTrue(LaunchRouting.runsAutomation(arguments), "\(arguments)")
        }
    }

    func testOnlyFirstArgumentDeterminesRouting() {
        XCTAssertFalse(LaunchRouting.runsAutomation(["-AppleLanguages", "(en)", "--help"]))
        XCTAssertTrue(LaunchRouting.runsAutomation(["status", "--ui-input-probe"]))
    }

    func testHelperExecutableInAppBundle() {
        let executable = URL(fileURLWithPath: "/Applications/getGamen.app/Contents/MacOS/getGamen")
        XCTAssertEqual(
            LaunchRouting.helperExecutable(forResolvedExecutable: executable).path,
            "/Applications/getGamen.app/Contents/Helpers/GetGamenAutomation.app/Contents/MacOS/getGamenAutomation")
    }

    func testRelaunchTargetResolvesSymlinkAndSkipsRealExecutable() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let executable = root.appendingPathComponent("getGamen.app/Contents/MacOS/getGamen")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let link = root.appendingPathComponent("bin/getGamen")
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: executable)

        let target = try XCTUnwrap(LaunchRouting.relaunchTarget(forInvokedExecutable: link))
        let resolved = try XCTUnwrap(realpath(executable.path, nil))
        defer { free(resolved) }
        let realPath = String(cString: resolved)
        XCTAssertEqual(target.path, realPath)
        XCTAssertNil(LaunchRouting.relaunchTarget(forInvokedExecutable: URL(fileURLWithPath: realPath)))

        guard realPath.hasPrefix("/private/") else {
            throw XCTSkip("Temporary directory is not under /private; parent symlink case is unavailable.")
        }
        let parentSymlinkPath = String(realPath.dropFirst("/private".count))
        XCTAssertEqual(
            LaunchRouting.relaunchTarget(forInvokedExecutable: URL(fileURLWithPath: parentSymlinkPath))?.path,
            realPath)
    }

    func testHelperExecutableInSwiftBuildDirectory() {
        let executable = URL(fileURLWithPath: "/project/.build/arm64-apple-macosx/debug/getGamen")
        XCTAssertEqual(
            LaunchRouting.helperExecutable(forResolvedExecutable: executable).path,
            "/project/.build/arm64-apple-macosx/debug/getGamenAutomation")
    }
}
