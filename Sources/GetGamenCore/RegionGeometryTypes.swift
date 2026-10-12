import Foundation

public enum RegionGeometryError: Error, Equatable {
    case invalidGeometry, invalidDisplayIdentity, ambiguousOverlap, noDisplayIntersection
    case unsupportedVersion(Int), topologyChanged, arithmeticOverflow
}

extension RegionGeometryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry: return "撮影範囲の指定が正しくありません。範囲を選び直してください。"
        case .invalidDisplayIdentity: return "ディスプレイを識別できませんでした。もう一度撮影してください。"
        case .ambiguousOverlap: return "重なり合ったディスプレイにまたがる範囲は撮影できません。範囲を選び直してください。"
        case .noDisplayIntersection: return "撮影範囲がどのディスプレイにも入っていません。範囲を選び直してください。"
        case .unsupportedVersion: return "範囲の情報の形式に対応していません。範囲を選び直してください。"
        case .topologyChanged: return "撮影中に画面の構成が変わりました。もう一度撮影してください。"
        case .arithmeticOverflow: return "撮影範囲が大きすぎて計算できません。範囲を選び直してください。"
        }
    }
}

/// Signed point rectangle. Constructors store values; RegionGeometry validates and normalizes them.
public struct RegionRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// `frame` uses global AppKit y-up points; backing dimensions use native pixels.
public struct RegionDisplay: Codable, Equatable, Sendable {
    public let id: String
    public let runtimeID: UInt32
    public let frame: RegionRect
    public let scale: Double
    public let rotation: Double
    public let backingWidth: Int
    public let backingHeight: Int
    public let mirrorSourceID: String?
    public init(id: String, runtimeID: UInt32, frame: RegionRect, scale: Double, rotation: Double, backingWidth: Int, backingHeight: Int, mirrorSourceID: String? = nil) {
        self.id = id
        self.runtimeID = runtimeID
        self.frame = frame
        self.scale = scale
        self.rotation = rotation
        self.backingWidth = backingWidth
        self.backingHeight = backingHeight
        self.mirrorSourceID = mirrorSourceID
    }
}

/// Display origins relative to the selected anchor, in AppKit y-up points.
public struct RegionDisplayReference: Codable, Equatable, Sendable {
    public let id: String
    public let relativeX: Double
    public let relativeY: Double
    public let width: Double
    public let height: Double
    public let scale: Double
    public let rotation: Double
    public let backingWidth: Int
    public let backingHeight: Int
    public let mirrorSourceID: String?
    public init(id: String, relativeX: Double, relativeY: Double, width: Double, height: Double, scale: Double, rotation: Double, backingWidth: Int, backingHeight: Int, mirrorSourceID: String? = nil) {
        self.id = id
        self.relativeX = relativeX
        self.relativeY = relativeY
        self.width = width
        self.height = height
        self.scale = scale
        self.rotation = rotation
        self.backingWidth = backingWidth
        self.backingHeight = backingHeight
        self.mirrorSourceID = mirrorSourceID
    }
}

/// `dragInAnchor` uses top-left y-down points relative to the anchor display.
public struct RegionSelection: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let anchorID: String
    public let dragInAnchor: RegionRect
    public let displays: [RegionDisplayReference]
    public init(schemaVersion: Int, anchorID: String, dragInAnchor: RegionRect, displays: [RegionDisplayReference]) {
        self.schemaVersion = schemaVersion
        self.anchorID = anchorID
        self.dragInAnchor = dragInAnchor
        self.displays = displays
    }
}

public struct RegionPixelRect: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// `sourceRect` is display-local top-left y-down points; `pixelSize` is native pixels.
/// `destination` is a top-left pixel rectangle in the output at `RegionCapturePlan.outputScale`.
public struct RegionTile: Codable, Equatable, Sendable {
    public let displayID: String
    public let runtimeID: UInt32
    public let sourceRect: RegionRect
    public let pixelSize: PixelSize
    public let destination: RegionPixelRect
    public init(displayID: String, runtimeID: UInt32, sourceRect: RegionRect, pixelSize: PixelSize, destination: RegionPixelRect) {
        self.displayID = displayID
        self.runtimeID = runtimeID
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
        self.destination = destination
    }
}

public struct RegionCapturePlan: Codable, Equatable, Sendable {
    public let selection: RegionSelection
    public let outputSize: PixelSize
    public let outputScale: Double
    public let tiles: [RegionTile]
    public init(selection: RegionSelection, outputSize: PixelSize, outputScale: Double, tiles: [RegionTile]) {
        self.selection = selection
        self.outputSize = outputSize
        self.outputScale = outputScale
        self.tiles = tiles
    }
}

