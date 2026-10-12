import AppKit
import Foundation

@MainActor
public enum AutomationCLI {
    public static let help = """
    Usage: getGamen <command> [options]
      status                         Screen Recording permission status (JSON)
      authorize                      Explicitly request Screen Recording permission
      displays                       Display coordinates (Quartz global points, primary top-left origin, y downward)
      windows                        Visible window IDs
      capture-window --window-id ID --output PATH [--cursor]
      capture-region --x X --y Y --width W --height H --output PATH [--cursor]
      convert --input PATH --output PATH [--format png|png8|jpeg] [--quality 0.9]
      edit --input PATH --output PATH --edits '{"crop":{"x":0,"y":0,"width":100,"height":100}}'
      tools                          JSON tool catalog and argument schemas
      mcp                            Start newline-delimited JSON-RPC over stdio
      --help                         Show this help
      --version                      Print bundle version

    All capture/edit/convert commands accept --format and JPEG --quality.
    Any tool also accepts --json '{...}' instead of named options.
    Outputs never overwrite existing files. Parent folders must exist.
    CLI success: JSON on stdout. Failure: JSON on stderr; exit 2 for bad arguments,
    1 for execution errors. No arguments or single-dash AppKit arguments (for example
    -AppleLanguages) launch the GUI; -h shows this help.
    """

    public static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let command = arguments.first else { throw AutomationFailure("invalid_arguments", "A command is required") }
            if ["--help", "help", "-h"].contains(command) {
                guard arguments.count == 1 else { throw invalid() }
                print(help); return 0
            }
            if command == "--version" {
                guard arguments.count == 1 else { throw invalid() }
                print(MCPServer.bundleVersion); return 0
            }
            if ["mcp", "tools", "authorize"].contains(command) {
                guard arguments.count == 1 else { throw invalid() }
                if command == "tools" { print(try MCPServer.json(["tools": AutomationCatalog.tools])); return 0 }
                if command == "authorize" {
                    let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
                    print(try MCPServer.json(["screen_recording": granted, "restart_required": !CGPreflightScreenCaptureAccess()]))
                    return granted ? 0 : 1
                }
                let service = AutomationService()
                try await MCPServer(execute: service.execute).serve()
                return 0
            }
            let (name, values) = try parse(arguments)
            let result = try await AutomationService().execute(name, arguments: values)
            print(try MCPServer.json(result))
            return 0
        } catch {
            let failure = AutomationService.failure(error)
            let text = (try? MCPServer.json(["error": failure])) ?? "{\"error\":\"serialization failed\"}"
            let data = Data((text + "\n").utf8)
            try? FileHandle.standardError.write(contentsOf: data)
            return ["invalid_arguments", "unknown_tool"].contains(failure["code"] as? String ?? "") ? 2 : 1
        }
    }

    public static func parse(_ arguments: [String]) throws -> (String, [String: Any]) {
        guard let command = arguments.first else { throw invalid() }
        let name = command.replacingOccurrences(of: "-", with: "_")
        guard let tool = AutomationCatalog.tools.first(where: { $0["name"] as? String == name }),
              let schema = tool["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]] else {
            throw AutomationFailure("unknown_tool", "Unknown command: \(command). Use --help.")
        }
        var values: [String: Any] = [:]
        if arguments.count >= 2 && arguments[1] == "--json" {
            guard arguments.count == 3,
                  let object = try jsonArgument(arguments[2]) as? [String: Any] else { throw invalid() }
            values = object
        } else {
            var index = 1
            while index < arguments.count {
                let option = arguments[index]
                guard option.hasPrefix("--") else { throw invalid() }
                let key = String(option.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
                guard values[key] == nil, let property = properties[key] else { throw invalid() }
                if property["type"] as? String == "boolean" { values[key] = true; index += 1; continue }
                guard index + 1 < arguments.count else { throw invalid() }
                let text = arguments[index + 1]
                switch property["type"] as? String {
                case "number", "integer":
                    guard let n = Double(text), n.isFinite else { throw invalid() }; values[key] = n
                case "object":
                    values[key] = try jsonArgument(text)
                default: values[key] = text
                }
                index += 2
            }
        }
        return (name, values)
    }
    private static func jsonArgument(_ text: String) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        catch { throw invalid() }
    }
    private static func invalid() -> AutomationFailure { AutomationFailure("invalid_arguments", "Invalid or duplicate options. Use --help or tools for the argument schema.") }
}
