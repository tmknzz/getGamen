import CoreGraphics
import Foundation
import GetGamenCore

enum ImageActionError: LocalizedError, Equatable {
    case invalidRegion
    case invalidQuality
    case invalidImage
    case imageTooLarge
    case multipleFrames
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .invalidRegion:
            return "範囲が画像の外か、指定が正しくありません（円は幅と高さを同じに、線の太さは0より大きく、モザイクのブロックサイズは1〜100にしてください）。"
        case .invalidQuality:
            return "JPEG の品質は 0〜1 で指定してください。"
        case .imageTooLarge:
            return "画像が大きすぎるか、画像の大きさの情報が壊れています。"
        case .invalidImage:
            return "画像として読み込めませんでした。PNG や JPEG などの画像ファイルを指定してください。"
        case .multipleFrames:
            return "アニメーションなど複数の画像を含むファイルは扱えません。1枚だけの画像を指定してください。"
        case .processingFailed:
            return "画像を処理できませんでした。"
        }
    }
}

/// Pure image transforms for the App Intents layer. Each takes original image
/// bytes and returns new image bytes, reusing the editor's render pipeline
/// (RasterImageDecoder → EditState.validate → EditRenderer → RasterImageCodec)
/// without introducing any new drawing. Regions are pixels, top-left origin.
enum ImageActions {
    /// Apple's standard orange, the frame color (#FF9500).
    private static let borderColor = RGBColor(red: 1.0, green: 149.0 / 255.0, blue: 0.0)
    private static let maskColor = RGBColor(red: 0, green: 0, blue: 0)

    static func convert(_ data: Data, format: RasterImageCodec.Format) throws -> Data {
        try translatingErrors(data) {
            try RasterImageCodec.encode(RasterImageDecoder.decode(data), format: format)
        }
    }

    static func crop(_ data: Data, x: Int, y: Int, width: Int, height: Int) throws -> Data {
        try edit(data, EditState(crop: PixelCrop(x: x, y: y, width: width, height: height)))
    }

    static func border(_ data: Data, x: Int, y: Int, width: Int, height: Int,
                       shape: OutlineShape = .rectangle,
                       lineWidth: Double = 3, cornerRadius: Double = 12) throws -> Data {
        // cornerRadius only applies to a rounded rectangle; clamp it between zero
        // and the half short side EditState.validate() allows, and zero it for other shapes.
        let radius = shape == .roundedRectangle
            ? max(0, min(cornerRadius, Double(min(width, height)) / 2)) : 0
        let style = OutlineStyle(shape: shape, color: borderColor, lineWidth: lineWidth, cornerRadius: radius)
        return try edit(data, EditState(objects: [object(x, y, width, height, .outline(style))]))
    }

    static func mask(_ data: Data, x: Int, y: Int, width: Int, height: Int) throws -> Data {
        try edit(data, EditState(objects: [object(x, y, width, height, .colorMask(color: maskColor))]))
    }

    static func mosaic(_ data: Data, x: Int, y: Int, width: Int, height: Int,
                       blockSize: Int = 12) throws -> Data {
        try edit(data, EditState(objects: [object(x, y, width, height, .mosaic(blockSize: blockSize))]))
    }

    private static func object(_ x: Int, _ y: Int, _ width: Int, _ height: Int,
                               _ style: EditStyle) -> EditObject {
        EditObject(id: UUID(),
                   bounds: PixelBounds(x: Double(x), y: Double(y),
                                       width: Double(width), height: Double(height)),
                   style: style)
    }

    /// Edits keep lossless PNG output; use convert to change the format.
    private static func edit(_ data: Data, _ edits: EditState) throws -> Data {
        try translatingErrors(data) {
            let rendered = try EditRenderer.render(original: RasterImageDecoder.decode(data), edits: edits)
            return try RasterImageCodec.encode(rendered, format: .png)
        }
    }

    private static func translatingErrors(_ data: Data, _ body: () throws -> Data) throws -> Data {
        guard data.count <= RasterImageDecoder.maxFileBytes else {
            throw ImageActionError.imageTooLarge
        }
        do {
            return try body()
        } catch DocumentStoreError.invalidEdits {
            throw ImageActionError.invalidRegion
        } catch RasterImageCodec.EncodingError.invalidQuality {
            throw ImageActionError.invalidQuality
        } catch RasterImageDecoder.DecodingError.invalidDimensions {
            throw ImageActionError.imageTooLarge
        } catch RasterImageDecoder.DecodingError.unsupportedImageCount {
            throw ImageActionError.multipleFrames
        } catch is RasterImageDecoder.DecodingError {
            throw ImageActionError.invalidImage
        } catch {
            // Decoded input that still fails to render or encode is not the caller's file format.
            throw ImageActionError.processingFailed
        }
    }
}
