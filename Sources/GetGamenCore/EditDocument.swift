import Foundation

public enum DocumentStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int), corruptDocument, documentIdentityMismatch
    case originalMismatch, invalidPixelSize, emptyOriginal, invalidEdits
    case revisionConflict(expected: UInt64, actual: UInt64)
    case revisionOverflow, unsafeFileType
}

public struct PixelSize: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    func validate() throws {
        guard width > 0, height > 0, !width.multipliedReportingOverflow(by: height).overflow else {
            throw DocumentStoreError.invalidPixelSize
        }
    }
}

public struct PixelBounds: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct PixelCrop: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct RGBColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
}

public enum OutlineShape: String, Codable, Sendable {
    case rectangle, roundedRectangle, circle, ellipse
}

public struct OutlineStyle: Codable, Equatable, Sendable {
    public var shape: OutlineShape
    public var color: RGBColor
    public var lineWidth: Double
    public var cornerRadius: Double
    public init(shape: OutlineShape, color: RGBColor, lineWidth: Double, cornerRadius: Double) {
        self.shape = shape; self.color = color
        self.lineWidth = lineWidth; self.cornerRadius = cornerRadius
    }
}

public enum EditStyle: Codable, Equatable, Sendable {
    case outline(OutlineStyle)
    case grayMask(brightness: Double)
    case colorMask(color: RGBColor)
    case mosaic(blockSize: Int)
}

public struct EditObject: Codable, Equatable, Sendable {
    public let id: UUID
    public var bounds: PixelBounds
    public var style: EditStyle
    public init(id: UUID, bounds: PixelBounds, style: EditStyle) {
        self.id = id; self.bounds = bounds; self.style = style
    }
}

public struct ImageBorder: Codable, Equatable, Sendable {
    public var brightness: Double
    public var width: Int
    public var color: RGBColor?
    public var resolvedColor: RGBColor { color ?? RGBColor(red: brightness, green: brightness, blue: brightness) }
    public init(brightness: Double, width: Int) { self.brightness = brightness; self.width = width }
    public init(color: RGBColor, width: Int) { self.brightness = 0.6; self.color = color; self.width = width }
}

public struct EditState: Codable, Equatable, Sendable {
    public var objects: [EditObject]
    public var crop: PixelCrop?
    public var border: ImageBorder?
    public init(objects: [EditObject] = [], crop: PixelCrop? = nil, border: ImageBorder? = nil) {
        self.objects = objects; self.crop = crop; self.border = border
    }

    /// Coordinates belong to the original image, including objects outside the crop.
    public func validate(pixelSize: PixelSize) throws {
        try pixelSize.validate()
        if let border {
            guard border.brightness.isFinite, (0...1).contains(border.brightness),
                  [border.resolvedColor.red, border.resolvedColor.green, border.resolvedColor.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  (1...100).contains(border.width) else { throw DocumentStoreError.invalidEdits }
        }
        var ids = Set<UUID>()
        for object in objects {
            let b = object.bounds
            guard ids.insert(object.id).inserted,
                  [b.x, b.y, b.width, b.height, b.x + b.width, b.y + b.height].allSatisfy(\.isFinite),
                  b.x >= 0, b.y >= 0, b.width > 0, b.height > 0,
                  b.x + b.width <= Double(pixelSize.width),
                  b.y + b.height <= Double(pixelSize.height) else {
                throw DocumentStoreError.invalidEdits
            }
            switch object.style {
            case .outline(let style):
                guard [style.color.red, style.color.green, style.color.blue].allSatisfy({
                    $0.isFinite && (0...1).contains($0)
                }), style.lineWidth.isFinite, style.lineWidth > 0,
                    style.cornerRadius.isFinite, style.cornerRadius >= 0,
                    style.cornerRadius <= min(b.width, b.height) / 2,
                    style.shape != .circle || b.width == b.height else {
                    throw DocumentStoreError.invalidEdits
                }
            case .grayMask(let brightness):
                guard brightness.isFinite, (0...1).contains(brightness) else {
                    throw DocumentStoreError.invalidEdits
                }
            case .colorMask(let color):
                guard [color.red, color.green, color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw DocumentStoreError.invalidEdits
                }
            case .mosaic(let blockSize):
                guard (1...100).contains(blockSize) else { throw DocumentStoreError.invalidEdits }
            }
        }
        if let crop {
            guard crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
                  crop.width <= pixelSize.width, crop.height <= pixelSize.height,
                  crop.x <= pixelSize.width - crop.width,
                  crop.y <= pixelSize.height - crop.height else {
                throw DocumentStoreError.invalidEdits
            }
        }
    }
}

/// Schema v1 uses Foundation's default Date Codable representation (reference-date seconds).
public struct EditDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let documentID: UUID
    public let originalID: UUID
    public let originalSHA256: String
    public let originalByteCount: Int
    public let pixelSize: PixelSize
    public let createdAt: Date
    public let revision: UInt64
    public let edits: EditState
}

public struct StoredDocument: Equatable, Sendable {
    public let document: EditDocument
    public let originalData: Data
}
