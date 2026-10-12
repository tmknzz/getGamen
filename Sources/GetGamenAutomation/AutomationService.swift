import AppKit
import ScreenCaptureKit
import GetGamenCore

public struct SchemaViolation: Error {
    public let failure: AutomationFailure
    public init(failure: AutomationFailure) { self.failure = failure }
}

@MainActor
public final class AutomationService {
    private let licenseState: @MainActor () async -> LicenseState

    public convenience init() {
        let license = LicenseManager()
        self.init(licenseState: { await license.automationState() })
    }

    init(licenseState: @escaping @MainActor () async -> LicenseState) {
        self.licenseState = licenseState
    }

    /// Converts between Quartz y-down and AppKit y-up global points in either direction.
    nonisolated static func convertScreenRect(_ rect: RegionRect, displays: [RegionDisplay]) throws -> RegionRect {
        guard let primary = displays.first(where: { $0.frame.x == 0 && $0.frame.y == 0 }) else {
            throw AutomationFailure("operation_failed", "Primary display is unavailable; refresh displays and retry.")
        }
        return RegionRect(x: rect.x, y: primary.frame.height - rect.y - rect.height,
            width: rect.width, height: rect.height)
    }

    nonisolated static func displaysOutput(_ displays: [RegionDisplay]) throws -> [String: Any] {
        return ["coordinate_system": "Quartz global points; top-left origin of the primary display, y increasing downward",
                "displays": try displays.map { display in
                    let frame = try convertScreenRect(display.frame, displays: displays)
                    return ["id": display.id, "runtime_id": display.runtimeID,
                        "x": frame.x, "y": frame.y,
                        "width": frame.width, "height": frame.height,
                        "scale": display.scale] as [String: Any]
                }]
    }

    nonisolated static func licenseOutput(_ state: LicenseState) -> [String: Any] {
        var output: [String: Any] = ["purchase_url": LicenseConfig.purchaseURL.absoluteString]
        switch state {
        case .trial(let days): output["state"] = "trial"; output["trial_days_remaining"] = days
        case .licensed: output["state"] = "licensed"
        case .free: output["state"] = "free"
        }
        return output
    }

    static func launcherPath(bundleURL: URL, executableURL: URL?) -> String {
        let path: String
        if bundleURL.deletingLastPathComponent().lastPathComponent == "Helpers" {
            path = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacOS/getGamen").standardizedFileURL.path
        } else {
            path = executableURL?.deletingLastPathComponent()
                .appendingPathComponent("getGamen").standardizedFileURL.path ?? "getGamen"
        }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-")
        guard path.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        return path
    }

    private static let launcherCommand = launcherPath(
        bundleURL: Bundle.main.bundleURL, executableURL: Bundle.main.executableURL)

    public func execute(_ name: String, arguments a: [String: Any]) async throws -> [String: Any] {
        do {
            try AutomationCatalog.validate(name: name, arguments: a)
        } catch let failure as AutomationFailure {
            throw SchemaViolation(failure: failure)
        }
        let license = await licenseState()
        if name == "status" {
            return ["screen_recording": CGPreflightScreenCaptureAccess(),
                    "permission_help": "Grant Screen Recording to the launching app in System Settings > Privacy & Security, then restart the client. Run \(Self.launcherCommand) authorize to request access explicitly.",
                    "license": Self.licenseOutput(license)]
        }
        guard license.allowsAutomation else {
            throw AutomationFailure("license_required", "The getGamen CLI and MCP tools need a license after the \(LicenseConfig.trialDays)-day trial. Buy one at \(LicenseConfig.purchaseURL.absoluteString), then enter the key in getGamen Settings > ライセンス (License). Manual use in the app stays free.")
        }
        if name == "displays" {
            let displays = try await RegionCaptureService().snapshot()
            return try Self.displaysOutput(displays)
        }
        if name == "windows" {
            return ["windows": try await windows().map { ["id": $0.windowID, "title": $0.title ?? "",
                "application": $0.owningApplication?.applicationName ?? "",
                "pid": $0.owningApplication?.processID ?? 0] as [String: Any] }]
        }
        // Validate all export options before capturing or reading input.
        let output = URL(fileURLWithPath: a["output"] as! String).standardizedFileURL
        let format = try exportFormat(a)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw AutomationFailure("output_exists", "Output already exists: \(output.path)")
        }
        let image: CGImage
        switch name {
        case "capture_window":
            guard let id = UInt32(exactly: (a["window_id"] as! NSNumber).doubleValue), id > 0,
                  let window = try await windows().first(where: { $0.windowID == id }) else {
                throw AutomationFailure("window_not_found", "Window is unavailable; refresh windows and choose a current ID.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = try WindowCaptureGeometry.pixelSize(contentRect: filter.contentRect,
                pointPixelScale: Double(filter.pointPixelScale))
            try checkSize(width: Double(size.width), height: Double(size.height))
            let configuration = try WindowCaptureGeometry.configuration(contentRect: filter.contentRect,
                pointPixelScale: Double(filter.pointPixelScale), showsCursor: a["cursor"] as? Bool ?? false)
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        case "capture_region":
            let rect = RegionRect(x: number(a, "x"), y: number(a, "y"), width: number(a, "width"), height: number(a, "height"))
            let service = RegionCaptureService()
            let displays = try await service.snapshot()
            let appKitRect = try Self.convertScreenRect(rect, displays: displays)
            let selection = try RegionGeometry.select(drag: appKitRect, displays: displays)
            let plan = try RegionGeometry.plan(selection: selection, displays: displays)
            try checkSize(width: Double(plan.outputSize.width), height: Double(plan.outputSize.height))
            let exclusions = try await service.prepareExclusions(windows: [])
            defer { service.cancel() }
            image = try await service.capture(selection: selection, exclusions: exclusions, showsCursor: a["cursor"] as? Bool ?? false)
        case "convert", "edit":
            let input = URL(fileURLWithPath: a["input"] as! String).standardizedFileURL
            let original = try RasterImageDecoder.decode(RasterImageDecoder.readFile(input))
            try checkSize(width: Double(original.width), height: Double(original.height))
            if name == "edit" {
                let state = try editState(a["edits"] as! [String: Any])
                do {
                    try state.validate(pixelSize: PixelSize(width: original.width, height: original.height))
                } catch DocumentStoreError.invalidEdits {
                    throw AutomationFailure("invalid_arguments", "Edits extend outside the image or contain invalid values.")
                }
                image = try EditRenderer.render(original: original, edits: state)
            } else {
                image = original
            }
        default: throw SchemaViolation(failure: AutomationFailure("unknown_tool", "Unknown operation: \(name)"))
        }
        let data = try RasterImageCodec.encode(image, format: format)
        // O_EXCL semantics also reject symlinks and concurrent writers; never overwrite.
        try data.write(to: output, options: .withoutOverwriting)
        return ["path": output.path, "width": image.width, "height": image.height, "bytes": data.count,
                "format": a["format"] as? String ?? "png"]
    }

    private func windows() async throws -> [SCWindow] {
        guard CGPreflightScreenCaptureAccess() else {
            throw AutomationFailure("permission_required", "Screen Recording permission is required. Run \(Self.launcherCommand) authorize, allow access in System Settings, and restart the client.")
        }
        return try await DirectWindowPicker.capturableWindows()
    }

    private func checkSize(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 64_000_000 else {
            throw AutomationFailure("image_too_large", "Image dimensions must be positive and at most 64 million pixels.")
        }
    }

    private func exportFormat(_ a: [String: Any]) throws -> RasterImageCodec.Format {
        let format = a["format"] as? String ?? "png"
        if a["quality"] != nil && format != "jpeg" {
            throw AutomationFailure("invalid_arguments", "quality is only valid with format jpeg")
        }
        switch format {
        case "png8": return .png8
        case "jpeg": return .jpeg(quality: (a["quality"] as? NSNumber)?.doubleValue ?? 0.9)
        default: return .png
        }
    }

    private func number(_ a: [String: Any], _ key: String, default fallback: Double = 0) -> Double {
        (a[key] as? NSNumber)?.doubleValue ?? fallback
    }
    private func color(_ a: [String: Any]?) -> GetGamenCore.RGBColor {
        let a = a ?? ["red": 0, "green": 0, "blue": 0]
        return GetGamenCore.RGBColor(red: number(a, "red"), green: number(a, "green"), blue: number(a, "blue"))
    }
    private func editState(_ a: [String: Any]) throws -> EditState {
        var state = EditState()
        if let c = a["crop"] as? [String: Any] {
            state.crop = PixelCrop(x: (c["x"] as! NSNumber).intValue, y: (c["y"] as! NSNumber).intValue,
                width: (c["width"] as! NSNumber).intValue, height: (c["height"] as! NSNumber).intValue)
        }
        if let b = a["border"] as? [String: Any] {
            state.border = ImageBorder(color: color(b["color"] as? [String: Any]), width: (b["width"] as! NSNumber).intValue)
        }
        for object in a["objects"] as? [[String: Any]] ?? [] {
            let b = object["bounds"] as! [String: Any]
            let style: EditStyle
            let type = object["type"] as! String
            let allowed: Set<String>
            switch type {
            case "mask":
                allowed = ["type", "bounds", "color"]
                style = .colorMask(color: color(object["color"] as? [String: Any]))
            case "mosaic":
                allowed = ["type", "bounds", "block_size"]
                style = .mosaic(blockSize: (object["block_size"] as? NSNumber)?.intValue ?? 12)
            default:
                allowed = ["type", "bounds", "shape", "color", "line_width", "corner_radius"]
                style = .outline(OutlineStyle(shape: OutlineShape(rawValue: object["shape"] as? String ?? "rectangle")!,
                    color: color(object["color"] as? [String: Any]), lineWidth: number(object, "line_width", default: 3),
                    cornerRadius: number(object, "corner_radius", default: 8)))
            }
            guard Set(object.keys).isSubset(of: allowed) else {
                throw AutomationFailure("invalid_arguments", "An edit contains options incompatible with its type.")
            }
            state.objects.append(EditObject(id: UUID(), bounds: PixelBounds(x: number(b, "x"), y: number(b, "y"),
                width: number(b, "width"), height: number(b, "height")), style: style))
        }
        return state
    }

    public static func failure(_ error: Error) -> [String: Any] {
        if let error = error as? SchemaViolation { return failure(error.failure) }
        if let error = error as? AutomationFailure { return ["code": error.code, "message": error.message] }
        if let error = error as? WindowCaptureService.CaptureError, error == .invalidGeometry {
            return ["code": "image_too_large", "message": "Window size is invalid or too large to capture."]
        }
        if let error = error as? RegionCaptureError, error == .permissionRequired {
            return ["code": "permission_required", "message": "Screen Recording permission is required. Run \(Self.launcherCommand) authorize and restart the client after granting access."]
        }
        return ["code": "operation_failed", "message": String(describing: error)]
    }
}
