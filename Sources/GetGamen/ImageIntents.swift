import AppIntents
import Foundation
import GetGamenCore
import UniformTypeIdentifiers

enum ImageFormatChoice: String, AppEnum {
    case png, png8, jpeg
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "画像形式")
    static let caseDisplayRepresentations: [ImageFormatChoice: DisplayRepresentation] = [
        .png: "PNG", .png8: "PNG（8ビット）", .jpeg: "JPEG"
    ]

    func codecFormat(quality: Double) -> RasterImageCodec.Format {
        switch self {
        case .png: return .png
        case .png8: return .png8
        case .jpeg: return .jpeg(quality: quality)
        }
    }

    var fileExtension: String {
        switch self {
        case .png, .png8: return "png"
        case .jpeg: return "jpg"
        }
    }

    var contentType: UTType {
        switch self {
        case .png, .png8: return .png
        case .jpeg: return .jpeg
        }
    }
}

enum OutlineShapeChoice: String, AppEnum {
    case rectangle, roundedRectangle, circle, ellipse
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "枠の形")
    static let caseDisplayRepresentations: [OutlineShapeChoice: DisplayRepresentation] = [
        .rectangle: "四角", .roundedRectangle: "角丸", .circle: "円", .ellipse: "楕円"
    ]
    // Cases mirror OutlineShape one-to-one; ImageActionsTests checks every case.
    var outlineShape: OutlineShape { OutlineShape(rawValue: rawValue)! }
}

private func pngResult(_ data: Data, _ name: String) -> IntentFile {
    IntentFile(data: data, filename: "\(name).png", type: .png)
}

struct ConvertImageIntent: AppIntent {
    static let title: LocalizedStringResource = "画像を変換"
    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"]) var image: IntentFile
    @Parameter(title: "形式") var format: ImageFormatChoice
    @Parameter(title: "JPEG 品質", default: 0.9, inclusiveRange: (0, 1)) var quality: Double

    static var parameterSummary: some ParameterSummary {
        When(\.$format, .equalTo, .jpeg) {
            Summary("\(\.$image) を \(\.$format) に変換") { \.$quality }
        } otherwise: {
            Summary("\(\.$image) を \(\.$format) に変換")
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = try ImageActions.convert(image.data, format: format.codecFormat(quality: quality))
        return .result(value: IntentFile(data: data, filename: "converted.\(format.fileExtension)", type: format.contentType))
    }
}

struct CropImageIntent: AppIntent {
    static let title: LocalizedStringResource = "画像をクロップ"
    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"]) var image: IntentFile
    @Parameter(title: "X") var x: Int
    @Parameter(title: "Y") var y: Int
    @Parameter(title: "幅") var width: Int
    @Parameter(title: "高さ") var height: Int

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = try ImageActions.crop(image.data, x: x, y: y, width: width, height: height)
        return .result(value: pngResult(data, "cropped"))
    }
}

struct BorderImageIntent: AppIntent {
    static let title: LocalizedStringResource = "枠で囲む"
    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"]) var image: IntentFile
    @Parameter(title: "X") var x: Int
    @Parameter(title: "Y") var y: Int
    @Parameter(title: "幅") var width: Int
    @Parameter(title: "高さ") var height: Int
    @Parameter(title: "形", default: .rectangle) var shape: OutlineShapeChoice
    @Parameter(title: "線の太さ", default: 3.0, inclusiveRange: (0.5, 100)) var lineWidth: Double
    @Parameter(title: "角丸半径", default: 12.0, inclusiveRange: (0, 1000)) var cornerRadius: Double

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = try ImageActions.border(image.data, x: x, y: y, width: width, height: height,
                                           shape: shape.outlineShape, lineWidth: lineWidth,
                                           cornerRadius: cornerRadius)
        return .result(value: pngResult(data, "bordered"))
    }
}

struct MaskImageIntent: AppIntent {
    static let title: LocalizedStringResource = "マスクをかける"
    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"]) var image: IntentFile
    @Parameter(title: "X") var x: Int
    @Parameter(title: "Y") var y: Int
    @Parameter(title: "幅") var width: Int
    @Parameter(title: "高さ") var height: Int

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = try ImageActions.mask(image.data, x: x, y: y, width: width, height: height)
        return .result(value: pngResult(data, "masked"))
    }
}

struct MosaicImageIntent: AppIntent {
    static let title: LocalizedStringResource = "モザイクをかける"
    @Parameter(title: "画像", supportedTypeIdentifiers: ["public.image"]) var image: IntentFile
    @Parameter(title: "X") var x: Int
    @Parameter(title: "Y") var y: Int
    @Parameter(title: "幅") var width: Int
    @Parameter(title: "高さ") var height: Int
    @Parameter(title: "ブロックサイズ", default: 12, inclusiveRange: (1, 100)) var blockSize: Int

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = try ImageActions.mosaic(image.data, x: x, y: y, width: width, height: height, blockSize: blockSize)
        return .result(value: pngResult(data, "mosaic"))
    }
}
