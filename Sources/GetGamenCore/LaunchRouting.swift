import Darwin
import Foundation

public enum LaunchRouting {
    /// Returns the real executable location when the invocation needs relaunching.
    /// Compares the realpath(3) result against the invoked path verbatim so that
    /// Foundation standardization cannot strip `/private` and trigger another relaunch.
    public static func relaunchTarget(forInvokedExecutable invoked: URL) -> URL? {
        guard let resolved = realpath(invoked.path, nil) else { return nil }
        defer { free(resolved) }
        let realPath = String(cString: resolved)
        return realPath == invoked.path ? nil : URL(fileURLWithPath: realPath)
    }

    /// Accepts launch arguments excluding the executable name.
    /// Uses the GUI path for no arguments, a first argument with Finder's `-psn_` prefix,
    /// the diagnostic flags `--smoke-output`, `--ui-input-probe`, and `--ui-quit-smoke`,
    /// or single-dash AppKit/NSUserDefaults arguments such as `-AppleLanguages`.
    /// A first argument of `-h` and all other first arguments go to the automation helper.
    public static func runsAutomation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        if ["--smoke-output", "--ui-input-probe", "--ui-quit-smoke"].contains(first) {
            return false
        }
        return first == "-h" || !first.hasPrefix("-") || first.hasPrefix("--")
    }

    /// Locates the helper from an executable URL whose symbolic links are already resolved.
    public static func helperExecutable(forResolvedExecutable executable: URL) -> URL {
        let directory = executable.deletingLastPathComponent()
        let contents = directory.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        if directory.lastPathComponent == "MacOS",
           contents.lastPathComponent == "Contents",
           app.pathExtension == "app" {
            return app.appendingPathComponent(
                "Contents/Helpers/GetGamenAutomation.app/Contents/MacOS/getGamenAutomation")
        }
        return directory.appendingPathComponent("getGamenAutomation")
    }
}
