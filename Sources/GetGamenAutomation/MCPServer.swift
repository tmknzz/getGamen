import Foundation
import CoreFoundation
import Darwin

/// Sequential stdio MCP server. No HTTP listener, persistent background agent or UI state.
@MainActor
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"
    static let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    private let version: String
    private var initialized = false
    private var ready = false
    private let execute: (String, [String: Any]) async throws -> [String: Any]

    public init(version: String? = nil, execute: @escaping (String, [String: Any]) async throws -> [String: Any]) {
        self.version = version ?? Self.bundleVersion
        self.execute = execute
    }

    public func handle(_ data: Data) async -> [String: Any]? {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
        catch { return self.error(id: NSNull(), code: -32700, message: "Parse error") }
        guard let request = value as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return error(id: NSNull(), code: -32600, message: "Invalid Request")
        }
        let id = request["id"]
        if let id, !(id is String) {
            guard let n = id as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                return error(id: NSNull(), code: -32600, message: "Invalid request ID")
            }
        }
        guard let id else {
            if method == "notifications/initialized", initialized { ready = true }
            return nil
        }
        guard request["params"] == nil || request["params"] is [String: Any] else {
            return error(id: id, code: -32602, message: "params must be an object")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        func result(_ body: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": body] }
        if method == "ping" { return result([:]) }
        if method == "initialize" {
            guard !initialized, let version = params["protocolVersion"] as? String,
                  params["capabilities"] is [String: Any], params["clientInfo"] is [String: Any] else {
                return error(id: id, code: -32602, message: "Expected first initialize with protocolVersion, capabilities and clientInfo")
            }
            initialized = true
            let supported = ["2024-11-05", "2025-03-26", Self.protocolVersion]
            return result(["protocolVersion": supported.contains(version) ? version : Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "getGamen", "version": self.version],
                "instructions": "Tools operate on local files and screens. Output paths must be new. Screen capture requires macOS Screen Recording permission. Use status first. No GUI document state is changed."])
        }
        guard ready else { return error(id: id, code: -32002, message: "Initialize and send notifications/initialized first") }
        switch method {
        case "tools/list":
            guard params["cursor"] == nil else { return error(id: id, code: -32602, message: "This server has no pagination cursor") }
            return result(["tools": AutomationCatalog.tools])
        case "tools/call":
            guard let name = params["name"] as? String,
                  params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return error(id: id, code: -32602, message: "Expected tool name and object arguments")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let output = try await execute(name, arguments)
                return result(["content": [["type": "text", "text": try Self.json(output)]], "isError": false])
            } catch let violation as SchemaViolation {
                return self.error(id: id, code: -32602, message: violation.failure.message)
            } catch {
                let failure = AutomationService.failure(error)
                return result(["content": [["type": "text", "text": (try? Self.json(["error": failure])) ?? "Tool failed"]], "isError": true])
            }
        default: return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async throws {
        var line = Data()
        var oversized = false
        // A fixed-size read bounds memory even when a client never sends a newline.
        while true {
            let chunk = try await Self.readChunk(descriptor: input.fileDescriptor)
            if chunk.isEmpty { break }
            for byte in chunk {
                if byte == 10 {
                    let response: [String: Any]?
                    if oversized { response = error(id: NSNull(), code: -32700, message: "Message exceeds 1 MiB") }
                    else if line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { response = nil }
                    else { response = await handle(line) }
                    if let response { try output.write(contentsOf: Data((try Self.json(response) + "\n").utf8)) }
                    line.removeAll(keepingCapacity: true); oversized = false
                } else if !oversized {
                    if line.count >= 1_048_576 { oversized = true; line.removeAll(keepingCapacity: true) }
                    else { line.append(byte) }
                }
            }
        }
        // EOF closes the session; an unterminated frame is not executed.
    }

    private nonisolated static func readChunk(descriptor: Int32) async throws -> [UInt8] {
        try await Task.detached {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                // One POSIX read returns the available pipe bytes without
                // waiting to fill the buffer, and never blocks MainActor.
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count >= 0 { return Array(buffer.prefix(count)) }
                if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }.value
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
