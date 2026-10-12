import AppKit
import Darwin
import GetGamenCore

@main
@MainActor
enum GetGamenApp {
    private static let relaunchEnvironmentKey = "GETGAMEN_RELAUNCHED"

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if getenv(relaunchEnvironmentKey) != nil {
            unsetenv(relaunchEnvironmentKey)
        } else if let executable = Bundle.main.executableURL,
           let target = LaunchRouting.relaunchTarget(forInvokedExecutable: executable) {
            setenv(relaunchEnvironmentKey, "1", 1)
            let error = exec(target.path, arguments: arguments)
            let message = "Unable to relaunch GetGamen at \(target.path): \(String(cString: strerror(error)))\n"
            unsetenv(relaunchEnvironmentKey)
            FileHandle.standardError.write(Data(message.utf8))
        }
        if LaunchRouting.runsAutomation(arguments) {
            // Replace this process before AppKit registers the GUI bundle with
            // Launch Services. Automation has its own background-only identity.
            guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
                FileHandle.standardError.write(Data("Unable to locate GetGamen executable.\n".utf8))
                exit(1)
            }
            let helper = LaunchRouting.helperExecutable(forResolvedExecutable: executable)
            let error = exec(helper.path, arguments: arguments)
            let message = "Unable to launch GetGamen automation helper: \(String(cString: strerror(error)))\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = GetGamenApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func exec(_ path: String, arguments: [String]) -> Int32 {
        let strings = ([path] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        return argv.withUnsafeMutableBufferPointer { buffer in
            _ = execv(path, buffer.baseAddress!)
            let error = errno
            return error
        }
    }
}

@MainActor
final class GetGamenApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: ApplicationController?
    private var pendingOpenURLs: [URL] = []
    private var terminationApproved = false
    #if DEBUG
    private var inputDiagnostics: NativeInputDiagnostics?
    #endif

    nonisolated static func isShortcutsRunner(path: String?) -> Bool {
        path?.contains("/WorkflowKit.framework/") == true
    }

    nonisolated static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    // Shortcuts runs intents via WorkflowKit's BackgroundShortcutRunner, which sends
    // launch/reopen events (observed on macOS 26). An openAppWhenRun cold launch
    // has no event and is not a default launch.
    // ponytail: the private framework path is an observed, undocumented marker;
    // replace it if Apple provides an official signal.
    nonisolated static func isShortcutsEvent(_ event: NSAppleEventDescriptor?, launchIsDefault: Bool?) -> Bool {
        if let event {
            let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
            return isShortcutsRunner(path: pid.flatMap(executablePath(pid:)))
        }
        return launchIsDefault == false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["GETGAMEN_UI_TEST_ROOT"] {
                let defaults = UserDefaults(suiteName: "getGamen.ui." + URL(fileURLWithPath: path).lastPathComponent)!
                if ProcessInfo.processInfo.environment["GETGAMEN_UI_PRESERVE_DEFAULTS"] != "1" {
                    defaults.removePersistentDomain(forName: "getGamen.ui." + URL(fileURLWithPath: path).lastPathComponent)
                }
                let output = URL(fileURLWithPath: path).appendingPathComponent("exports")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                controller = try ApplicationController(root: URL(fileURLWithPath: path), defaults: defaults)
                try controller?.exportSettings.setDestinationFolder(output)
            } else { controller = try ApplicationController() }
            #else
            controller = try ApplicationController()
            #endif
            controller?.install()
            if pendingOpenURLs.isEmpty {
                if ProcessInfo.processInfo.arguments.contains("--smoke-output") {
                    controller?.chooser.show()
                } else if !Self.isShortcutsEvent(NSAppleEventManager.shared().currentAppleEvent,
                    launchIsDefault: notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) {
                    // A cold Dock launch must take the same path as a reopen.
                    controller?.chooser.reopenFromDock()
                }
            }
            if !pendingOpenURLs.isEmpty {
                let urls = pendingOpenURLs
                pendingOpenURLs.removeAll()
                application(NSApp, open: urls)
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-input-probe"), let controller {
                inputDiagnostics = try NativeInputDiagnostics(routing: controller.routing)
            }
            if ProcessInfo.processInfo.environment["GETGAMEN_UI_CREATE_FIXTURE"] == "1",
               let path = ProcessInfo.processInfo.environment["GETGAMEN_UI_TEST_ROOT"] {
                let output = URL(fileURLWithPath: path).appendingPathComponent("source.png")
                if !FileManager.default.fileExists(atPath: output.path) {
                    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let context = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 800,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RasterImageCodec.EncodingError.encodingFailed }
                    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
                    context.fill(CGRect(x: 0,y: 0,width: 200,height: 150))
                    guard let image = context.makeImage() else { throw RasterImageCodec.EncodingError.encodingFailed }
                    try RasterImageCodec.encode(image, format: .png).write(to: output, options: .withoutOverwriting)
                }
            }
            if let image = ProcessInfo.processInfo.environment["GETGAMEN_UI_TEST_IMAGE"] {
                controller?.library.importImages([URL(fileURLWithPath: image)])
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-quit-smoke"), let controller {
                Task { @MainActor in
                    await controller.library.waitUntilIdle()
                    controller.routing.perform(.quit)
                }
            }
            #endif
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let controller else { pendingOpenURLs.append(contentsOf: urls); return }
        controller.library.importImages(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isShortcutsEvent(NSAppleEventManager.shared().currentAppleEvent,
                                    launchIsDefault: nil) else { return false }
        // Present after AppKit finishes restoring the application's other windows,
        // so a visible editor/settings window cannot cover the capture chooser.
        Task { @MainActor [weak self] in
            self?.controller?.chooser.reopenFromDock()
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard let controller else { return .terminateNow }
        // terminateLater enters AppKit's termination run loop, which can starve
        // queued MainActor saves. Keep the normal loop alive during preflight.
        controller.requestTermination { [weak self] allowed in
            guard allowed, let self else { return }
            self.terminationApproved = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.uninstall()
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["GETGAMEN_UI_TEST_ROOT"] {
            let marker = URL(fileURLWithPath: path).appendingPathComponent("did-terminate")
            do { try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: marker, options: .atomic) }
            catch { NSLog("UI termination marker failed: %@", String(describing: error)) }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
