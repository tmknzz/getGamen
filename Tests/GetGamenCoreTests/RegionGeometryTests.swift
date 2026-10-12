import Foundation
import XCTest
@testable import GetGamenCore

final class RegionGeometryTests: XCTestCase {
    func testEveryGeometryErrorHasAMessage() {
        let errors: [RegionGeometryError] = [.invalidGeometry, .invalidDisplayIdentity, .ambiguousOverlap,
            .noDisplayIntersection, .unsupportedVersion(9), .topologyChanged, .arithmeticOverflow]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.contains("RegionGeometryError"), "\(error)")
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)")
        }
    }

    func testDragRectRoundTripsSavedSelections() throws {
        let cases: [(RegionRect, [RegionDisplay])] = [
            (rect(10, 70, 20, 10), [display("A")]),
            (rect(-90, -30, 20, 10), [display("A", x: -100, y: -100, scale: 2)]),
            (rect(10, 170, 20, 10), [display("A", y: 100)]),
            (rect(13.375, 74.375, -3.125, -4.125), [display("A", scale: 2)]),
            (rect(10.2, 70.2, 3.1, 4.1), [display("A", scale: 2)]),
            (rect(-10, -10, 120, 120), [display("A")]),
            (rect(-10, 20, 20, 10),
             [display("B", runtime: 2, scale: 2), display("A", x: -100)])
        ]
        for (drag, displays) in cases {
            let selection = try makePlan(drag, displays).selection
            let restored = try RegionGeometry.dragRect(for: selection, displays: displays)
            XCTAssertEqual(try RegionGeometry.select(drag: restored, displays: displays), selection)
        }
    }

    func testNegativeOriginAndAbovePrimaryUseActualDisplayTopEdge() throws {
        let negative = display("A", x: -100, y: 0, scale: 2)
        let first = try makePlan(rect(-90, 70, 20, 10), [negative])
        XCTAssertEqual(first.outputSize, PixelSize(width: 40, height: 20))
        XCTAssertEqual(first.selection.dragInAnchor, rect(10, 20, 20, 10))
        assertTile(try XCTUnwrap(first.tiles.first), source: rect(10, 20, 20, 10),
                   native: PixelSize(width: 40, height: 20), destination: pixels(0, 0, 40, 20))
        let above = try makePlan(rect(10, 170, 20, 10), [display("A", x: 0, y: 100)])
        XCTAssertEqual(above.outputSize, PixelSize(width: 20, height: 10))
        assertTile(try XCTUnwrap(above.tiles.first), source: rect(10, 20, 20, 10),
                   native: PixelSize(width: 20, height: 10), destination: pixels(0, 0, 20, 10))
    }

    func testFractionalOutwardSelectionIsSevenByNineAndReverseBinaryDragsAgree() throws {
        let screen = display("A", scale: 2)
        let result = try makePlan(rect(10.2, 70.2, 3.1, 4.1), [screen])
        XCTAssertEqual(result.outputSize, PixelSize(width: 7, height: 9))
        assertTile(try XCTUnwrap(result.tiles.first), source: rect(10, 25.5, 3.5, 4.5),
                   native: PixelSize(width: 7, height: 9), destination: pixels(0, 0, 7, 9))
        let forward = try makePlan(rect(10.25, 70.25, 3.125, 4.125), [screen])
        let reverse = try makePlan(rect(13.375, 74.375, -3.125, -4.125), [screen])
        XCTAssertEqual(forward, reverse)
        let horizontalReverse = try makePlan(rect(13.375, 70.25, -3.125, 4.125), [screen])
        XCTAssertEqual(forward, horizontalReverse)
    }

    func testMixedScaleSeamHasNoMissingOrDuplicatedColumn() throws {
        let result = try makePlan(rect(90, 20, 20, 10), [display("B", runtime: 2, x: 100, scale: 2), display("A")])
        XCTAssertEqual(result.outputScale, 2)
        XCTAssertEqual(result.outputSize, PixelSize(width: 40, height: 20))
        XCTAssertEqual(result.tiles.map(\.displayID), ["A", "B"])
        assertTile(result.tiles[0], source: rect(90, 70, 10, 10), native: PixelSize(width: 10, height: 10),
                   destination: pixels(0, 0, 20, 20))
        assertTile(result.tiles[1], source: rect(0, 70, 10, 10), native: PixelSize(width: 20, height: 20),
                   destination: pixels(20, 0, 20, 20))
        assertContainedAndDisjoint(result)
    }

    func testOneNativePixelAtFractionalPointEdgesDoesNotInflate() throws {
        let screen = display("A", width: 1000, height: 1000, scale: 3)
        let horizontal = try makePlan(rect(333.375, 0, 0.125, 1), [screen])
        XCTAssertEqual(horizontal.outputSize, PixelSize(width: 1, height: 3))
        XCTAssertEqual(horizontal.tiles[0].pixelSize, PixelSize(width: 1, height: 3))
        XCTAssertEqual(horizontal.tiles[0].destination, pixels(0, 0, 1, 3))
        let vertical = try makePlan(rect(0, 666.5, 1, 0.125), [screen])
        XCTAssertEqual(vertical.outputSize, PixelSize(width: 3, height: 1))
        XCTAssertEqual(vertical.tiles[0].pixelSize, PixelSize(width: 3, height: 1))
        XCTAssertEqual(vertical.tiles[0].destination, pixels(0, 0, 3, 1))
    }

    func testGapRetainsTransparentCanvasSpace() throws {
        let result = try makePlan(rect(90, 20, 30, 10), [display("A"), display("B", runtime: 2, x: 110, scale: 2)])
        XCTAssertEqual(result.outputSize, PixelSize(width: 60, height: 20))
        XCTAssertEqual(result.tiles[0].destination, pixels(0, 0, 20, 20))
        XCTAssertEqual(result.tiles[1].destination, pixels(40, 0, 20, 20))
        assertContainedAndDisjoint(result)
        let withMargins = try makePlan(rect(-10, -10, 120, 120), [display("A")])
        XCTAssertEqual(withMargins.outputSize, PixelSize(width: 120, height: 120))
        XCTAssertEqual(withMargins.tiles[0].destination, pixels(10, 10, 100, 100))
    }

    func testSingleSelectedDisplayRelocatesAndUsesNewRuntimeID() throws {
        let original = display("A", x: -100, scale: 2)
        let selection = try RegionGeometry.select(drag: rect(-90, 70, 20, 10), displays: [original, display("B", runtime: 2, x: 500)])
        let moved = display("A", runtime: 91, x: 300, y: -200, scale: 2)
        let result = try RegionGeometry.plan(selection: selection, displays: [moved])
        XCTAssertEqual(result.outputSize, PixelSize(width: 40, height: 20))
        XCTAssertEqual(result.tiles[0].runtimeID, 91)
        XCTAssertEqual(result.tiles[0].sourceRect, rect(10, 20, 20, 10))
        for changed in [display("A", x: -100, scale: 1), display("A", x: -100, scale: 2, rotation: 90),
                        display("A", x: -100, scale: 2, backingWidth: 199), display("A", x: -100, width: 99, scale: 2)] {
            assertError(.topologyChanged) { try RegionGeometry.plan(selection: selection, displays: [changed]) }
        }
        assertError(.topologyChanged) { try RegionGeometry.plan(selection: selection, displays: [display("B", runtime: 2)]) }
    }

    func testSelectedDisplaysTranslateTogetherButRelativeChangeOrNewGapDisplayRejects() throws {
        let a = display("A")
        let b = display("B", runtime: 2, x: 110, scale: 2)
        let selection = try RegionGeometry.select(drag: rect(90, 20, 30, 10), displays: [a, b])
        let moved = try RegionGeometry.plan(selection: selection, displays: [display("A", runtime: 10, x: -300, y: 150),
                                                                            display("B", runtime: 20, x: -190, y: 150, scale: 2)])
        XCTAssertEqual(moved.outputSize, PixelSize(width: 60, height: 20))
        XCTAssertEqual(moved.tiles.map(\.runtimeID), [10, 20])
        assertError(.topologyChanged) {
            try RegionGeometry.plan(selection: selection, displays: [a, display("B", runtime: 2, x: 111, scale: 2)])
        }
        assertError(.topologyChanged) {
            try RegionGeometry.plan(selection: selection, displays: [a, b, display("C", runtime: 3, x: 100, width: 10)])
        }
        let unaffected = try RegionGeometry.plan(selection: selection, displays: [a, b, display("C", runtime: 3, x: 500)])
        XCTAssertEqual(unaffected.tiles.count, 2)
    }

    func testFactualMirrorsDeduplicateSourceRegardlessOfArrayOrderOrFollowerScale() throws {
        let source = display("A", mirror: "A")
        let follower = display("B", runtime: 2, scale: 2, mirror: "A")
        let first = try makePlan(rect(10, 10, 20, 20), [source, follower])
        let second = try makePlan(rect(10, 10, 20, 20), [follower, source])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.outputScale, 1)
        XCTAssertEqual(first.tiles.map(\.displayID), ["A"])
        assertError(.ambiguousOverlap) { try makePlan(rect(10, 10, 20, 20), [display("A"), display("B", runtime: 2)]) }
        assertError(.invalidDisplayIdentity) { try makePlan(rect(10, 10, 20, 20), [display("A", mirror: "missing")]) }
        assertError(.invalidDisplayIdentity) {
            try makePlan(rect(10, 10, 20, 20), [display("A"), display("B", runtime: 2, mirror: "A")])
        }
        XCTAssertThrowsError(try makePlan(rect(10, 10, 20, 20), [source, display("B", runtime: 2, x: 1, mirror: "A")]))
        assertError(.ambiguousOverlap) {
            try makePlan(rect(90, 10, 20, 20), [display("A"), display("B", runtime: 2, x: 99)])
        }
    }

    func testHalfTieSnapAndIntegerSnapUseDifferentRules() {
        let half: Double = 10.5
        for value in [half.nextDown, half, half.nextUp] {
            XCTAssertEqual(RegionGeometry.tieSnap(value).rounded(.toNearestOrAwayFromZero), 11)
        }
        for value in [(-10.5).nextDown, -10.5, (-10.5).nextUp] {
            XCTAssertEqual(RegionGeometry.tieSnap(value).rounded(.toNearestOrAwayFromZero), -11)
        }
        XCTAssertEqual(RegionGeometry.tieSnap(10.5 - 1e-7).rounded(.toNearestOrAwayFromZero), 10)
        XCTAssertEqual(RegionGeometry.tieSnap(10.5 + 1e-7).rounded(.toNearestOrAwayFromZero), 11)
        let whole: Double = 10
        for value in [whole.nextDown, whole, whole.nextUp] {
            XCTAssertEqual(floor(RegionGeometry.integerSnap(value)), 10)
            XCTAssertEqual(ceil(RegionGeometry.integerSnap(value)), 10)
        }
        XCTAssertEqual(floor(RegionGeometry.integerSnap(10 - 1e-7)), 9)
        XCTAssertEqual(ceil(RegionGeometry.integerSnap(10 + 1e-7)), 11)
        XCTAssertEqual(floor(RegionGeometry.integerSnap(0.5)), 0)
        XCTAssertEqual(ceil(RegionGeometry.integerSnap(0.5)), 1)
    }

    func testActualAdjacentPlanSharesHalfPixelBoundaryAtColumnEleven() throws {
        let result = try makePlan(rect(0, 0, 10.25, 10), [display("A", width: 5.25, height: 10),
                                                         display("B", runtime: 2, x: 5.25, width: 5, height: 10, scale: 2)])
        XCTAssertEqual(result.outputSize, PixelSize(width: 21, height: 20))
        XCTAssertEqual(result.tiles[0].pixelSize, PixelSize(width: 6, height: 10),
                       "A genuinely fractional display edge still needs outward pixel coverage")
        XCTAssertEqual(result.tiles[0].destination, pixels(0, 0, 11, 20))
        XCTAssertEqual(result.tiles[1].destination, pixels(11, 0, 10, 20))
        assertContainedAndDisjoint(result)
    }

    func testAuthoritativeSharedEndpointSurvivesWouldBeReconstructionULP() throws {
        let left = -0.1
        let authoritative = 0.2
        XCTAssertNotEqual(left + (authoritative - left), authoritative,
                          "Fixture must expose endpoint reconstruction roundoff")
        let result = try makePlan(rect(-0.1, 0, 0.7, 4), [display("A", x: -0.2, width: 0.4, height: 4, scale: 10),
                                                        display("B", runtime: 2, x: 0.2, width: 0.4, height: 4, scale: 26.25)])
        XCTAssertEqual(result.outputSize, PixelSize(width: 19, height: 105))
        let first = result.tiles[0].destination
        let second = result.tiles[1].destination
        XCTAssertEqual(first.x + first.width, 9)
        XCTAssertEqual(second.x, 9)
        assertContainedAndDisjoint(result)
    }

    func testAnchorLocalRoundTripDoesNotInventAnAdjacentParticipant() throws {
        let screens = [display("A", x: -0.2, width: 0.4, height: 4, scale: 10),
                       display("B", runtime: 2, x: 0.2, width: 0.4, height: 4, scale: 10)]
        let selection = try RegionGeometry.select(drag: rect(0.1, 0, 0.1, 4), displays: screens)
        XCTAssertEqual(selection.displays.map(\.id), ["A"])
        let result = try RegionGeometry.plan(selection: selection, displays: screens)
        XCTAssertEqual(result.tiles.map(\.displayID), ["A"])
        XCTAssertEqual(result.outputSize, PixelSize(width: 1, height: 40))
        XCTAssertEqual(result.tiles[0].destination, pixels(0, 0, 1, 40))
        let intentionalCrossing = try makePlan(rect(0.1, 0, 0.1000001, 4), screens)
        XCTAssertEqual(intentionalCrossing.tiles.map(\.displayID), ["A", "B"],
                       "A crossing beyond numerical uncertainty must remain a real participant")
    }

    func testInvalidIdentityAndNoPositiveIntersection() {
        let drag = rect(1, 1, 5, 5)
        assertError(.invalidDisplayIdentity) { try makePlan(drag, [display("")]) }
        assertError(.invalidDisplayIdentity) { try makePlan(drag, [display("A", runtime: 0)]) }
        assertError(.invalidDisplayIdentity) { try makePlan(drag, [display("A"), display("A", runtime: 2, x: 100)]) }
        assertError(.invalidDisplayIdentity) { try makePlan(drag, [display("A"), display("B", runtime: 1, x: 100)]) }
        assertError(.noDisplayIntersection) { try makePlan(rect(100, 10, 10, 10), [display("A")]) }
        assertError(.noDisplayIntersection) { try makePlan(rect(10, 10, 1, 1), []) }
    }

    func testInvalidNumericsAndEndpointOverflow() {
        let drag = rect(1, 1, 5, 5)
        for value in [Double.nan, .infinity, -.infinity] {
            for invalidDrag in [rect(value, 1, 5, 5), rect(1, value, 5, 5), rect(1, 1, value, 5), rect(1, 1, 5, value)] {
                assertError(.invalidGeometry) { try makePlan(invalidDrag, [display("A")]) }
            }
            for screen in [display("A", x: value), display("A", y: value), display("A", width: value),
                           display("A", height: value), display("A", scale: value), display("A", rotation: value)] {
                assertError(.invalidGeometry) { try makePlan(drag, [screen]) }
            }
        }
        for invalid in [display("A", width: 0), display("A", width: -1), display("A", height: 0),
                        display("A", height: -1), display("A", scale: 0), display("A", scale: -1),
                        display("A", rotation: -1), display("A", rotation: 360),
                        display("A", backingWidth: 0), display("A", backingHeight: -1)] {
            assertError(.invalidGeometry) { try makePlan(drag, [invalid]) }
        }
        assertError(.invalidGeometry) { try makePlan(rect(1, 1, 0, 5), [display("A")]) }
        assertError(.invalidGeometry) { try makePlan(rect(1, 1, 5, 0), [display("A")]) }
        XCTAssertThrowsError(try makePlan(rect(Double.greatestFiniteMagnitude, 0, Double.greatestFiniteMagnitude, 1), [display("A")]))
        XCTAssertThrowsError(try makePlan(drag, [display("A", x: Double.greatestFiniteMagnitude, width: Double.greatestFiniteMagnitude)]))
        XCTAssertThrowsError(try makePlan(drag, [display("A", scale: Double.greatestFiniteMagnitude)]))
    }

    func testExactIntegerAndPixelByteOverflowReject() {
        assertError(.arithmeticOverflow) {
            try makePlan(rect(0, 0, 1, 1), [display("A", scale: Double(Int.max))])
        }
        assertError(.arithmeticOverflow) {
            try makePlan(rect(0, 0, 1, 1), [display("A", backingWidth: Int.max, backingHeight: 2)])
        }
        assertError(.arithmeticOverflow) {
            try makePlan(rect(0, 0, 2_000_000_000, 2_000_000_000),
                         [display("A", width: 2_000_000_000, height: 2_000_000_000)])
        }
    }

    func testPersistedSelectionRejectsUnknownSchemaDuplicatesAndForgedReferences() throws {
        let a = display("A")
        let selected = try RegionGeometry.select(drag: rect(10, 10, 20, 20), displays: [a])
        assertError(.unsupportedVersion(99)) {
            try RegionGeometry.plan(selection: copy(selected, schema: 99), displays: [a])
        }
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selected, references: []), displays: [a]))
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selected, references: selected.displays + selected.displays), displays: [a]))
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selected, anchor: "missing"), displays: [a]))
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selected, drag: rect(10, 10, -1, 2)), displays: [a]))
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selected, drag: rect(.nan, 10, 1, 2)), displays: [a]))
        let wrongOrigin = reference("A", relativeX: 1)
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selected, references: [wrongOrigin]), displays: [a]))
        let wrongScale = reference("A", scale: 2)
        assertError(.topologyChanged) { try RegionGeometry.plan(selection: copy(selected, references: [wrongScale]), displays: [a]) }
        let nonexistent = reference("Z", relativeX: 100)
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selected, references: selected.displays + [nonexistent]), displays: [a]))
        let pair = try RegionGeometry.select(drag: rect(90, 10, 20, 10), displays: [a, display("B", runtime: 2, x: 100)])
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(pair, references: Array(pair.displays.reversed())),
                                                    displays: [a, display("B", runtime: 2, x: 100)]))
        let encoded = try JSONEncoder().encode(selected)
        let decoded = try JSONDecoder().decode(RegionSelection.self, from: encoded)
        XCTAssertEqual(try RegionGeometry.plan(selection: decoded, displays: [a]), try RegionGeometry.plan(selection: selected, displays: [a]))
    }

    func testDecodedReferenceNumericFieldsAreNotTrusted() throws {
        let screen = display("A")
        let selection = try RegionGeometry.select(drag: rect(10, 10, 20, 20), displays: [screen])
        for invalid in [Double.nan, .infinity, -.infinity] {
            for field in 0..<6 {
                var values: [Double] = [0, 0, 100, 100, 1, 0]
                values[field] = invalid
                let bad = RegionDisplayReference(id: "A", relativeX: values[0], relativeY: values[1],
                                                 width: values[2], height: values[3], scale: values[4], rotation: values[5],
                                                 backingWidth: 200, backingHeight: 200)
                XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selection, references: [bad]), displays: [screen]))
            }
        }
        let badBacking = RegionDisplayReference(id: "A", relativeX: 0, relativeY: 0, width: 100, height: 100,
                                                scale: 1, rotation: 0, backingWidth: Int.max, backingHeight: 2)
        XCTAssertThrowsError(try RegionGeometry.plan(selection: copy(selection, references: [badBacking]), displays: [screen]))
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RegionRect {
        RegionRect(x: x, y: y, width: width, height: height)
    }
    private func pixels(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> RegionPixelRect {
        RegionPixelRect(x: x, y: y, width: width, height: height)
    }
    private func display(_ id: String, runtime: UInt32 = 1, x: Double = 0, y: Double = 0,
                         width: Double = 100, height: Double = 100, scale: Double = 1,
                         rotation: Double = 0, backingWidth: Int = 200, backingHeight: Int = 200,
                         mirror: String? = nil) -> RegionDisplay {
        RegionDisplay(id: id, runtimeID: runtime, frame: rect(x, y, width, height), scale: scale, rotation: rotation,
                      backingWidth: backingWidth, backingHeight: backingHeight, mirrorSourceID: mirror)
    }
    private func reference(_ id: String, relativeX: Double = 0, scale: Double = 1) -> RegionDisplayReference {
        RegionDisplayReference(id: id, relativeX: relativeX, relativeY: 0, width: 100, height: 100,
                               scale: scale, rotation: 0, backingWidth: 200, backingHeight: 200)
    }
    private func copy(_ selection: RegionSelection, schema: Int? = nil, anchor: String? = nil,
                      drag: RegionRect? = nil, references: [RegionDisplayReference]? = nil) -> RegionSelection {
        RegionSelection(schemaVersion: schema ?? selection.schemaVersion, anchorID: anchor ?? selection.anchorID,
                        dragInAnchor: drag ?? selection.dragInAnchor, displays: references ?? selection.displays)
    }
    private func makePlan(_ drag: RegionRect, _ displays: [RegionDisplay]) throws -> RegionCapturePlan {
        let selection = try RegionGeometry.select(drag: drag, displays: displays)
        return try RegionGeometry.plan(selection: selection, displays: displays)
    }
    private func assertError<T>(_ expected: RegionGeometryError, file: StaticString = #filePath, line: UInt = #line,
                                _ action: () throws -> T) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? RegionGeometryError, expected, file: file, line: line)
        }
    }
    private func assertTile(_ tile: RegionTile, source: RegionRect, native: PixelSize, destination: RegionPixelRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tile.sourceRect, source, file: file, line: line)
        XCTAssertEqual(tile.pixelSize, native, file: file, line: line)
        XCTAssertEqual(tile.destination, destination, file: file, line: line)
    }
    private func assertContainedAndDisjoint(_ plan: RegionCapturePlan, file: StaticString = #filePath, line: UInt = #line) {
        for (index, tile) in plan.tiles.enumerated() {
            let a = tile.destination
            XCTAssertGreaterThan(a.width, 0, file: file, line: line)
            XCTAssertGreaterThan(a.height, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.x, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.y, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(a.x + a.width, plan.outputSize.width, file: file, line: line)
            XCTAssertLessThanOrEqual(a.y + a.height, plan.outputSize.height, file: file, line: line)
            for other in plan.tiles.dropFirst(index + 1) {
                let b = other.destination
                XCTAssertFalse(min(a.x + a.width, b.x + b.width) > max(a.x, b.x)
                               && min(a.y + a.height, b.y + b.height) > max(a.y, b.y), file: file, line: line)
            }
        }
    }
}
