import AppKit
import Observation
import GetGamenCore
import UniformTypeIdentifiers

/// The width field's rules: range, rounding, presets and how typed text is read.
struct LineWidthRule {
    let range: ClosedRange<Double>
    /// Values are kept to 1 / scale pixels (10 = 0.1 px, 1 = whole pixels).
    let scale: Double
    let presets: [Double]

    static let outline = LineWidthRule(range: 0.5...100, scale: 10, presets: [0.5, 1, 2, 3, 4, 6, 8, 12, 16])
    /// ImageBorder stores whole pixels.
    static let imageBorder = LineWidthRule(range: 1...100, scale: 1, presets: [1, 2, 3, 4, 6, 8, 12, 16])

    /// Accepts full-width digits, surrounding spaces and a trailing "px". Nil when the text is not a number.
    func value(from text: String) -> Double? {
        var text = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasSuffix("px") { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        guard let number = Double(text), number.isFinite else { return nil }
        return min(max(rounded(number), range.lowerBound), range.upperBound)
    }

    /// Locale-independent so the field always reads back what it shows.
    func text(for value: Double) -> String {
        let value = rounded(value)
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func rounded(_ value: Double) -> Double { (value * scale).rounded() / scale }
}

@MainActor
@Observable
final class EditorInteraction {
    var selectsRangeFirst: Bool { tool == .none }
    enum Tool: String, CaseIterable {
        case none = "未選択"
        case select = "選択", rectangle = "四角", rounded = "角丸", circle = "丸", ellipse = "楕円"
        case mask = "マスク", mosaic = "モザイク", crop = "クロップ"
        case imageBorder = "画像全体の枠"

        var symbol: String {
            switch self {
            case .none: return ""
            case .select: return "cursorarrow"
            case .rectangle: return "rectangle"
            case .rounded: return "rectangle.roundedtop"
            case .circle: return "circle"
            case .ellipse: return "oval"
            case .mask: return "rectangle.fill"
            case .mosaic: return "square.grid.3x3.fill"
            case .crop: return "crop"
            case .imageBorder: return "rectangle.inset.filled"
            }
        }
    }
    let session: EditorSession
    var tool: Tool = .none
    private(set) var selected: Set<UUID> = []
    private(set) var preview: CGImage?
    private(set) var previewEdits: EditState?
    private var selectionAtStart: Set<UUID> = []
    private(set) var errorMessage: String?
    private(set) var pendingBounds: PixelBounds?
    var color: GetGamenCore.RGBColor
    var lineWidth: Double
    var radius: Double
    var maskColor: GetGamenCore.RGBColor?
    var brightness: Double { didSet { maskColor = nil } }
    var borderBrightness: Double = 0.6
    var borderColor: GetGamenCore.RGBColor?
    var borderWidth: Double = 1
    var blockSize: Double
    /// The editor slider range. CLI, MCP and saved documents still accept 1...100.
    static let blockSizeRange: ClosedRange<Double> = 2...40
    private let defaults: UserDefaults
    private var start: CGPoint?
    private var base = EditState()
    private var moving = false
    private var resizing = false
    private var newID = UUID()

    init(session: EditorSession, defaults: UserDefaults = .standard) {
        self.session = session; self.defaults = defaults
        func number(_ key: String, _ fallback: Double, _ limits: ClosedRange<Double>) -> Double {
            guard let value = defaults.object(forKey: "getGamen.edit." + key) as? Double,
                  value.isFinite, limits.contains(value) else { return fallback }
            return value
        }
        color = GetGamenCore.RGBColor(red: number("red", 1, 0...1), green: number("green", 0, 0...1), blue: number("blue", 0, 0...1))
        lineWidth = number("lineWidth", 3, LineWidthRule.outline.range)
        radius = number("radius", 12, 0...100)
        brightness = number("brightness", 0.5, 0...1)
        borderBrightness = session.draft.border?.brightness ?? number("borderBrightness", 0.6, 0...1)
        borderColor = session.draft.border?.color
        borderWidth = Double(session.draft.border?.width ?? Int(number("borderWidth", 1, LineWidthRule.imageBorder.range)))
        blockSize = number("blockSize", 12, Self.blockSizeRange)
    }

    func undo() {
        start = nil; pendingBounds = nil; selected.removeAll()
        session.undoEdit()
        preview = nil; previewEdits = nil
    }

    func chooseTool(_ value: Tool) {
        guard !session.isTerminationPending, start == nil else { return }
        tool = tool == value ? .none : value
        selected.removeAll()
        errorMessage = nil
        guard tool != .select, tool != .imageBorder, tool != .none else {
            pendingBounds = nil
            return
        }
        guard var bounds = pendingBounds, bounds.width >= 1, bounds.height >= 1 else {
            return
        }
        var edits = session.draft
        if value == .crop {
            let x = Int(floor(bounds.x)), y = Int(floor(bounds.y))
            edits.crop = PixelCrop(x: x, y: y, width: Int(ceil(bounds.x + bounds.width)) - x,
                                   height: Int(ceil(bounds.y + bounds.height)) - y)
            selected.removeAll()
        } else {
            if value == .circle { bounds.width = min(bounds.width, bounds.height); bounds.height = bounds.width }
            let id = UUID()
            edits.objects.append(EditObject(id: id, bounds: bounds, style: style(for: value, bounds: bounds)))
            selected = [id]
        }
        apply(edits, commit: true)
        pendingBounds = nil
    }

    func redo() {
        start = nil; pendingBounds = nil; selected.removeAll()
        session.redoEdit()
        preview = nil; previewEdits = nil
    }

    func imageDataForSaveAs(jpegQuality: Double) throws -> Data {
        let image = try session.renderDraft(session.draft)
        let format: RasterImageCodec.Format
        switch session.format {
        case .png: format = .png
        case .png8: format = .png8
        case .jpeg: format = .jpeg(quality: jpegQuality)
        }
        return try RasterImageCodec.encode(image, format: format)
    }

    func saveAs(jpegQuality: Double) {
        guard !session.isTerminationPending else { return }
        do {
            // Snapshot current edits and format before presenting the destination chooser.
            let data = try imageDataForSaveAs(jpegQuality: jpegQuality)
            let panel = NSSavePanel()
            panel.title = "名前を付けて保存"
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [session.format == .jpeg ? .jpeg : .png]
            panel.nameFieldStringValue = CaptureFilename.stem(createdAt: session.persisted.createdAt) + (session.format == .jpeg ? ".jpg" : ".png")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try data.write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "保存できませんでした: " + error.localizedDescription
        }
    }

    /// Flatten the current draft, without selection handles or an automatic save.
    func copyImage(to pasteboard: NSPasteboard = .general) throws {
        let image = try session.renderDraft(session.draft)
        try Self.writeImage(image, to: pasteboard)
    }

    static func writeImage(_ image: CGImage, to pasteboard: NSPasteboard) throws {
        let png = try RasterImageCodec.encode(image, format: .png)
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        // Finish rendering before replacing the user's clipboard.
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw NSError(domain: "getGamen.Clipboard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "画像をクリップボードにコピーできませんでした。"])
        }
    }

    /// Image-pixel dimensions, independent of the viewport zoom or display scale.
    var selectionSizeLabel: String? {
        if tool == .select, moving || resizing {
            if let bounds = selectedBounds { return pixelSizeLabel(bounds) }
        }
        if let bounds = pendingBounds { return pixelSizeLabel(bounds) }
        if tool != .crop, let bounds = selectedBounds { return pixelSizeLabel(bounds) }
        if let crop = session.draft.crop { return "\(crop.width) × \(crop.height) px" }
        return nil
    }

    private var selectedBounds: PixelBounds? {
        let objects = session.draft.objects.filter { selected.contains($0.id) }
        guard let x = objects.map(\.bounds.x).min(), let y = objects.map(\.bounds.y).min(),
              let right = objects.map({ $0.bounds.x + $0.bounds.width }).max(),
              let bottom = objects.map({ $0.bounds.y + $0.bounds.height }).max() else { return nil }
        return PixelBounds(x: x, y: y, width: right - x, height: bottom - y)
    }

    private func pixelSizeLabel(_ bounds: PixelBounds) -> String {
        let width = bounds.width > 0 ? Int(ceil(bounds.x + bounds.width) - floor(bounds.x)) : 0
        let height = bounds.height > 0 ? Int(ceil(bounds.y + bounds.height) - floor(bounds.y)) : 0
        return "\(width) × \(height) px"
    }

    func begin(_ point: CGPoint, shift: Bool) {
        guard (tool != .none || selectsRangeFirst), tool != .imageBorder, !session.isTerminationPending else { return }
        start = clamp(point); base = session.draft; newID = UUID(); moving = false; resizing = false
        pendingBounds = nil
        if selectsRangeFirst { selected.removeAll(); errorMessage = nil }
        if tool == .select {
            let p = clamp(point)
            if selected.count == 1, let object = base.objects.first(where: { selected.contains($0.id) }),
               abs(p.x - object.bounds.x - object.bounds.width) <= 8,
               abs(p.y - object.bounds.y - object.bounds.height) <= 8 {
                resizing = true
            } else if let hit = base.objects.last(where: { contains($0.bounds, p) }) {
                if shift {
                    if !selected.insert(hit.id).inserted { selected.remove(hit.id) }
                } else if !selected.contains(hit.id) { selected = [hit.id] }
                moving = selected.contains(hit.id)
            } else if !shift { selected = [] }
            selectionAtStart = selected
            if selected.count == 1, let object = base.objects.first(where: { selected.contains($0.id) }) {
                switch object.style {
                case .outline(let style): color = style.color; lineWidth = style.lineWidth; radius = style.cornerRadius
                case .grayMask(let value): brightness = value; maskColor = nil
                case .colorMask(let value): maskColor = value
                case .mosaic(let value):
                    blockSize = min(max(Double(value), Self.blockSizeRange.lowerBound), Self.blockSizeRange.upperBound)
                }
            }
        }
    }

    func drag(_ point: CGPoint) {
        guard !session.isTerminationPending, let start else { return }
        let end = clamp(point)
        var edits = base
        var bounds = PixelBounds(x: min(start.x, end.x), y: min(start.y, end.y),
                                 width: abs(end.x - start.x), height: abs(end.y - start.y))
        if tool == .circle && !selectsRangeFirst {
            let side = min(bounds.width, bounds.height)
            bounds = PixelBounds(x: end.x < start.x ? start.x - side : start.x,
                                 y: end.y < start.y ? start.y - side : start.y, width: side, height: side)
        }
        pendingBounds = bounds
        if selectsRangeFirst { return }
        if tool == .select {
            if moving {
                let objects = base.objects.filter { selected.contains($0.id) }
                guard let left = objects.map(\.bounds.x).min(), let top = objects.map(\.bounds.y).min(),
                      let right = objects.map({ $0.bounds.x + $0.bounds.width }).max(),
                      let bottom = objects.map({ $0.bounds.y + $0.bounds.height }).max() else { return }
                let dx = min(max(end.x - start.x, -left), Double(session.persisted.pixelSize.width) - right)
                let dy = min(max(end.y - start.y, -top), Double(session.persisted.pixelSize.height) - bottom)
                for index in edits.objects.indices where selected.contains(edits.objects[index].id) {
                    edits.objects[index].bounds.x += dx; edits.objects[index].bounds.y += dy
                }
            } else if resizing, let index = edits.objects.firstIndex(where: { selected.contains($0.id) }) {
                var b = edits.objects[index].bounds
                b.width = max(1, end.x - b.x); b.height = max(1, end.y - b.y)
                if case .outline(let style) = edits.objects[index].style, style.shape == .circle {
                    b.width = min(b.width, b.height); b.height = b.width
                }
                edits.objects[index].bounds = b
                edits.objects[index].style = constrained(edits.objects[index].style, bounds: b)
            } else {
                selected = selectionAtStart.union(base.objects.filter { intersects($0.bounds, bounds) }.map(\.id))
                return
            }
        } else {
            guard bounds.width >= 1, bounds.height >= 1 else { return }
            if tool == .crop {
                let x = Int(floor(bounds.x)), y = Int(floor(bounds.y))
                edits.crop = PixelCrop(x: x, y: y, width: Int(ceil(bounds.x + bounds.width)) - x,
                                       height: Int(ceil(bounds.y + bounds.height)) - y)
                // Keep the canvas transform stable until the pointer is released.
                session.setDraft(edits)
                return
            } else {
                edits.objects.append(EditObject(id: newID, bounds: bounds, style: style(for: tool, bounds: bounds)))
                selected = [newID]
            }
        }
        apply(edits, commit: false)
    }

    func end(_ point: CGPoint) {
        guard start != nil else { return }
        drag(point)
        if selectsRangeFirst {
            start = nil
            if let bounds = pendingBounds, bounds.width < 1 || bounds.height < 1 { pendingBounds = nil }
            return
        }
        start = nil; pendingBounds = nil
        guard !session.isTerminationPending, session.draft != base else { return }
        if tool == .crop { apply(session.draft, commit: true) }
        else { session.commitDraft() }
    }

    func deleteSelection() {
        var edits = session.draft
        edits.objects.removeAll { selected.contains($0.id) }
        selected = []
        apply(edits, commit: true)
    }
    func selectAll() { selected = Set(session.draft.objects.map(\.id)) }
    func clearSelection() { selected = [] }
    func resetCrop() { var edits = session.draft; edits.crop = nil; apply(edits, commit: true) }

    func setBorder(enabled: Bool) {
        var edits = session.draft
        edits.border = enabled ? ImageBorder(brightness: borderBrightness, width: Int(borderWidth)) : nil
        if enabled { edits.border?.color = borderColor }
        defaults.set(borderBrightness, forKey: "getGamen.edit.borderBrightness")
        defaults.set(borderWidth, forKey: "getGamen.edit.borderWidth")
        apply(edits, commit: true)
    }

    enum AttributeGroup { case outline, mask, mosaic }

    func commitAttributes(_ group: AttributeGroup) {
        guard !session.isTerminationPending else { return }
        for (key, value) in [("red", color.red), ("green", color.green), ("blue", color.blue),
                             ("lineWidth", lineWidth), ("radius", radius), ("brightness", brightness), ("blockSize", blockSize)] {
            defaults.set(value, forKey: "getGamen.edit." + key)
        }
        var edits = session.draft
        for index in edits.objects.indices where selected.contains(edits.objects[index].id) {
            let object = edits.objects[index]
            switch object.style {
            case .outline(var style):
                guard group == .outline else { continue }
                style.color = color; style.lineWidth = lineWidth; style.cornerRadius = min(radius, min(object.bounds.width, object.bounds.height) / 2)
                edits.objects[index].style = .outline(style)
            case .grayMask, .colorMask:
                guard group == .mask else { continue }
                edits.objects[index].style = maskStyle
            case .mosaic:
                guard group == .mosaic else { continue }
                edits.objects[index].style = .mosaic(blockSize: max(1, Int(blockSize)))
            }
        }
        apply(edits, commit: true)
    }

    private func apply(_ edits: EditState, commit: Bool) {
        guard !session.isTerminationPending else { return }
        do {
            let image = try session.renderDraft(edits)
            session.setDraft(edits); preview = image; previewEdits = edits; errorMessage = nil
            if commit { session.commitDraft() }
        } catch { errorMessage = error.localizedDescription }
    }
    private var maskStyle: EditStyle {
        maskColor.map { .colorMask(color: $0) } ?? .grayMask(brightness: brightness)
    }

    private func style(for tool: Tool, bounds: PixelBounds) -> EditStyle {
        switch tool {
        case .mask: return maskStyle
        case .mosaic: return .mosaic(blockSize: max(1, Int(blockSize)))
        default:
            let shape: OutlineShape = tool == .circle ? .circle : tool == .ellipse ? .ellipse : tool == .rounded ? .roundedRectangle : .rectangle
            return .outline(OutlineStyle(shape: shape, color: color, lineWidth: lineWidth, cornerRadius: min(radius, min(bounds.width, bounds.height) / 2)))
        }
    }
    private func constrained(_ style: EditStyle, bounds: PixelBounds) -> EditStyle {
        if case .outline(var outline) = style {
            outline.cornerRadius = min(outline.cornerRadius, min(bounds.width, bounds.height) / 2)
            return .outline(outline)
        }
        return style
    }
    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), Double(session.persisted.pixelSize.width)),
                y: min(max(point.y, 0), Double(session.persisted.pixelSize.height)))
    }
    private func contains(_ b: PixelBounds, _ p: CGPoint) -> Bool {
        p.x >= b.x && p.x <= b.x + b.width && p.y >= b.y && p.y <= b.y + b.height
    }
    private func intersects(_ a: PixelBounds, _ b: PixelBounds) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }
}
