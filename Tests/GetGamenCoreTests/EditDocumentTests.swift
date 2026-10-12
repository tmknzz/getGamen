import Foundation
import XCTest
import GetGamenCore

final class EditDocumentTests: XCTestCase {
    private let size = PixelSize(width: 320, height: 200)

    func testEveryEditStyleRoundTripsThroughPublicAPI() throws {
        var objects: [EditObject] = []
        for shape: OutlineShape in [.rectangle, .roundedRectangle, .circle, .ellipse] {
            objects.append(EditObject(id: UUID(), bounds: PixelBounds(x: 10, y: 20, width: 60, height: 60),
                style: .outline(OutlineStyle(shape: shape, color: RGBColor(red: 0.2, green: 0.4, blue: 0.8),
                                              lineWidth: 3, cornerRadius: 10))))
        }
        objects.append(EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 320, height: 200),
                                  style: .grayMask(brightness: 0.5)))
        objects.append(EditObject(id: UUID(), bounds: PixelBounds(x: 200, y: 100, width: 30, height: 40),
                                  style: .mosaic(blockSize: 12)))
        let state = EditState(objects: objects, crop: PixelCrop(x: 0, y: 0, width: 100, height: 100))
        try state.validate(pixelSize: size)
        let restored = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        // Cropping retains objects outside the viewport in original pixel coordinates.
        XCTAssertEqual(restored.objects.last?.bounds.x, 200)
    }

    func testRejectsInvalidGeometryColorsStylesAndDuplicateIdentifiers() throws {
        let good = PixelBounds(x: 0, y: 0, width: 20, height: 20)
        let invalidBounds = [
            PixelBounds(x: -1, y: 0, width: 20, height: 20),
            PixelBounds(x: 0, y: 0, width: 0, height: 20),
            PixelBounds(x: 310, y: 0, width: 20, height: 20),
            PixelBounds(x: .nan, y: 0, width: 20, height: 20),
            PixelBounds(x: 0, y: .infinity, width: 20, height: 20),
            PixelBounds(x: 0, y: 0, width: .greatestFiniteMagnitude, height: 20)
        ]
        for bounds in invalidBounds {
            assertInvalid(EditState(objects: [EditObject(id: UUID(), bounds: bounds, style: .grayMask(brightness: 0.5))], crop: nil))
        }
        let invalidStyles: [EditStyle] = [
            .grayMask(brightness: -0.1), .grayMask(brightness: 1.1), .grayMask(brightness: .nan),
            .mosaic(blockSize: 0), .mosaic(blockSize: -1),
            .mosaic(blockSize: 101), .mosaic(blockSize: Int.max),
            .outline(OutlineStyle(shape: .rectangle, color: RGBColor(red: .infinity, green: 0, blue: 0), lineWidth: 1, cornerRadius: 0)),
            .outline(OutlineStyle(shape: .rectangle, color: RGBColor(red: 0, green: -1, blue: 0), lineWidth: 1, cornerRadius: 0)),
            .outline(OutlineStyle(shape: .rectangle, color: RGBColor(red: 0, green: 0, blue: 0), lineWidth: 0, cornerRadius: 0)),
            .outline(OutlineStyle(shape: .roundedRectangle, color: RGBColor(red: 0, green: 0, blue: 0), lineWidth: 1, cornerRadius: 11))
        ]
        for style in invalidStyles {
            assertInvalid(EditState(objects: [EditObject(id: UUID(), bounds: good, style: style)], crop: nil))
        }
        let circle = EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 20, height: 21),
                                style: .outline(OutlineStyle(shape: .circle, color: RGBColor(red: 0, green: 0, blue: 0), lineWidth: 1, cornerRadius: 0)))
        assertInvalid(EditState(objects: [circle], crop: nil))
        let same = EditObject(id: UUID(), bounds: good, style: .grayMask(brightness: 1))
        assertInvalid(EditState(objects: [same, same], crop: nil))
    }

    func testMosaicBlockSizeBoundariesAreValid() throws {
        for blockSize in [1, 100] {
            let object = EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 20, height: 20),
                                    style: .mosaic(blockSize: blockSize))
            try EditState(objects: [object]).validate(pixelSize: size)
        }
    }

    func testCropAndSourceDimensionBoundariesDoNotOverflow() throws {
        for crop in [PixelCrop(x: -1, y: 0, width: 1, height: 1),
                     PixelCrop(x: 0, y: 0, width: 0, height: 1),
                     PixelCrop(x: Int.max, y: 0, width: Int.max, height: 1),
                     PixelCrop(x: 0, y: 199, width: 1, height: 2)] {
            assertInvalid(EditState(objects: [], crop: crop))
        }
        try EditState(objects: [], crop: PixelCrop(x: 319, y: 199, width: 1, height: 1)).validate(pixelSize: size)
        for invalid in [PixelSize(width: 0, height: 1), PixelSize(width: -1, height: 1), PixelSize(width: Int.max, height: 2)] {
            XCTAssertThrowsError(try EditState(objects: [], crop: nil).validate(pixelSize: invalid))
        }
    }

    private func assertInvalid(_ state: EditState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try state.validate(pixelSize: size), file: file, line: line) { error in
            XCTAssertEqual(error as? DocumentStoreError, .invalidEdits, file: file, line: line)
        }
    }
}
