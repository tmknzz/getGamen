import AppKit
import Darwin
import Foundation

/// Deliberately requested smoke diagnostics. Images are native app-view renderings,
/// not desktop screenshots; this path never requests screen recording access.
@MainActor
final class LaunchDiagnostics {
    static let shared = LaunchDiagnostics()
    private var windows: [String: NSWindow] = [:]
    private var started = false

    struct WindowResult: Codable {
        let role: String
        let title: String
        let visible: Bool
        let width: Double
        let height: Double
        let image: String?
    }

    struct Report: Codable {
        let schemaVersion: Int
        let passed: Bool
        let renderingKind: String
        let bundleIdentifier: String
        let minimumOS: String
        let version: String
        let build: String
        let windows: [WindowResult]
        let errors: [String]
    }

    func observe(_ window: NSWindow, role: String) {
        guard ProcessInfo.processInfo.arguments.contains("--smoke-output") else { return }
        windows[role] = window
    }

    func runIfRequested(openSettings: () -> Void) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--smoke-output"), !started else { return }
        started = true
        guard arguments.indices.contains(flag + 1) else {
            failWithoutReport("--smoke-output requires a directory")
        }
        let output = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for name in ["result.json", "main.png", "settings.png"] {
                guard !FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path) else {
                    failWithoutReport("Refusing to overwrite existing smoke evidence: \(name)")
                }
            }
        } catch { failWithoutReport("Cannot prepare smoke output: \(error)") }

        NSApp.activate()
        var errors: [String] = []
        if await waitForWindow("main") {
            openSettings()
            if !(await waitForWindow("settings")) { errors.append("Settings window visibility deadline exceeded") }
        } else {
            errors.append("Main window visibility deadline exceeded")
        }
        // Allow pending layout/display work to finish after native window visibility.
        do { try await Task.sleep(for: .milliseconds(250)) }
        catch { errors.append("Diagnostic task cancelled") }

        let results = ["main", "settings"].map { role -> WindowResult in
            guard let window = windows[role], let view = window.contentView else {
                errors.append("Missing native window or content view: \(role)")
                return WindowResult(role: role, title: "", visible: false, width: 0, height: 0, image: nil)
            }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            let usable = window.isVisible && bounds.width > 0 && bounds.height > 0
            var image: String?
            if usable {
                do {
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                        throw RenderError.unavailable
                    }
                    view.cacheDisplay(in: bounds, to: bitmap)
                    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                          let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
                        throw RenderError.unavailable
                    }
                    let filename = "\(role).png"
                    try data.write(to: output.appendingPathComponent(filename), options: .withoutOverwriting)
                    image = filename
                } catch { errors.append("Native view rendering failed for \(role): \(error)") }
            } else { errors.append("Native window is not visible and usable: \(role)") }
            return WindowResult(role: role, title: window.title, visible: window.isVisible,
                                width: Double(bounds.width), height: Double(bounds.height), image: image)
        }
        func metadata(_ key: String) -> String {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
            if value.isEmpty { errors.append("Missing bundle metadata: \(key)") }
            return value
        }
        let bundleIdentifier = metadata("CFBundleIdentifier")
        let minimumOS = metadata("LSMinimumSystemVersion")
        let version = metadata("CFBundleShortVersionString")
        let build = metadata("CFBundleVersion")
        let passed = errors.isEmpty && results.count == 2 && results.allSatisfy {
            $0.visible && $0.width > 0 && $0.height > 0 && $0.image != nil
        }
        let report = Report(schemaVersion: 1, passed: passed, renderingKind: "native-app-view-rendering",
                            bundleIdentifier: bundleIdentifier, minimumOS: minimumOS, version: version,
                            build: build, windows: results, errors: errors)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent("result.json"), options: .withoutOverwriting)
        } catch { failWithoutReport("Cannot write smoke report: \(error)") }
        exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private func waitForWindow(_ role: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            if let window = windows[role], window.isVisible,
               let bounds = window.contentView?.bounds, bounds.width > 0, bounds.height > 0 { return true }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        return false
    }

    private enum RenderError: Error { case unavailable }

    private func failWithoutReport(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}
