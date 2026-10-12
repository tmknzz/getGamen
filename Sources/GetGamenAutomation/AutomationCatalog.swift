import Foundation
import CoreFoundation

public struct AutomationFailure: Error, LocalizedError {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// One contract shared by the CLI parser, MCP discovery and runtime validation.
public enum AutomationCatalog {
    static let path: [String: Any] = ["type": "string", "minLength": 1, "description": "Local file path. Output files must not already exist."]
    static let number: [String: Any] = ["type": "number"]
    static let integer: [String: Any] = ["type": "integer"]
    static let boolean: [String: Any] = ["type": "boolean"]
    static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    static let bounds = object(["x": number, "y": number, "width": number, "height": number], required: ["x", "y", "width", "height"])
    static let crop = object(["x": integer, "y": integer, "width": integer, "height": integer], required: ["x", "y", "width", "height"])
    static let color = object(["red": number, "green": number, "blue": number], required: ["red", "green", "blue"])
    static let edits = object([
        "crop": crop,
        "border": object(["width": integer, "color": color], required: ["width", "color"]),
        "objects": ["type": "array", "maxItems": 100, "items": object([
            "type": ["type": "string", "enum": ["mask", "mosaic", "outline"]],
            "bounds": bounds, "color": color, "block_size": integer,
            "shape": ["type": "string", "enum": ["rectangle", "roundedRectangle", "circle", "ellipse"]],
            "line_width": number, "corner_radius": number
        ], required: ["type", "bounds"])]
    ])
    static let export: [String: Any] = [
        "output": path,
        "format": ["type": "string", "enum": ["png", "png8", "jpeg"], "description": "Default png. Independent of file extension."],
        "quality": ["type": "number", "minimum": 0, "maximum": 1, "description": "JPEG only. Default 0.9."]
    ]
    static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = [], readOnly: Bool = true) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": object(properties, required: required),
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "idempotentHint": readOnly, "openWorldHint": false]]
    }
    public static let tools: [[String: Any]] = [
        tool("status", "Report screen recording permission without prompting."),
        tool("displays", "List displays with Quartz global point coordinates (top-left origin of the primary display, y increasing downward)."),
        tool("windows", "List currently visible windows and their IDs. Requires screen recording permission."),
        tool("capture_window", "Capture a visible window by ID; save a new file and return its path and pixel dimensions.", export.merging(["window_id": integer, "cursor": boolean]) { _, b in b }, required: ["window_id", "output"], readOnly: false),
        tool("capture_region", "Capture a rectangle in Quartz global points, top-left origin of the primary display, y increasing downward; use displays to find coordinates.", export.merging(["x": number, "y": number, "width": number, "height": number, "cursor": boolean]) { _, b in b }, required: ["x", "y", "width", "height", "output"], readOnly: false),
        tool("convert", "Convert a local image to PNG, indexed PNG or JPEG; never overwrite the input or an existing file.", export.merging(["input": path]) { _, b in b }, required: ["input", "output"], readOnly: false),
        tool("edit", "Render crop, border, masks, mosaics and outlines using original-image pixels with top-left origin. Colors are RGB in 0...1. Saves a new file, leaves source unchanged.", export.merging(["input": path, "edits": edits]) { _, b in b }, required: ["input", "output", "edits"], readOnly: false)
    ]

    public static func validate(name: String, arguments: [String: Any]) throws {
        guard let tool = tools.first(where: { $0["name"] as? String == name }), let schema = tool["inputSchema"] as? [String: Any] else {
            throw AutomationFailure("unknown_tool", "Unknown operation: \(name)")
        }
        try validate(arguments, schema: schema, at: "arguments")
    }

    private static func validate(_ value: Any, schema: [String: Any], at key: String) throws {
        func invalid() -> AutomationFailure { AutomationFailure("invalid_arguments", "Invalid value or type at \(key)") }
        switch schema["type"] as? String {
        case "object":
            guard let values = value as? [String: Any], let properties = schema["properties"] as? [String: Any],
                  Set(values.keys).isSubset(of: Set(properties.keys)),
                  (schema["required"] as? [String] ?? []).allSatisfy({ values[$0] != nil }) else { throw invalid() }
            for (name, item) in values {
                try validate(item, schema: properties[name] as! [String: Any], at: "\(key).\(name)")
            }
        case "array":
            guard let values = value as? [Any], values.count <= (schema["maxItems"] as? Int ?? 100),
                  let item = schema["items"] as? [String: Any] else { throw invalid() }
            for (index, value) in values.enumerated() { try validate(value, schema: item, at: "\(key)[\(index)]") }
        case "string":
            guard let text = value as? String, !text.isEmpty,
                  !(text.contains("\0")) else { throw invalid() }
            if let choices = schema["enum"] as? [String], !choices.contains(text) { throw invalid() }
        case "boolean":
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw invalid() }
        case "number", "integer":
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw invalid() }
            if schema["type"] as? String == "integer", Int(exactly: n.doubleValue) == nil { throw invalid() }
            if let min = schema["minimum"] as? NSNumber, n.doubleValue < min.doubleValue { throw invalid() }
            if let max = schema["maximum"] as? NSNumber, n.doubleValue > max.doubleValue { throw invalid() }
        default: throw invalid()
        }
    }
}
