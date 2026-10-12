import AppKit
import GetGamenAutomation

@main
@MainActor
enum AutomationHost {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        // ScreenCaptureKit requires WindowServer initialization. The separate
        // background-only bundle keeps this registration away from the GUI.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = Array(CommandLine.arguments.dropFirst())
        Task { @MainActor in exit(await AutomationCLI.run(arguments)) }
        RunLoop.main.run()
    }
}
