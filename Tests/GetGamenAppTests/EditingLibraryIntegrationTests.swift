import AppKit
import XCTest
@testable import GetGamen
@testable import GetGamenCore

@MainActor
final class EditingLibraryIntegrationTests: XCTestCase {
    func testBothEditingWorkflowsApplyEachToolOnceAndUndo() async throws {
        for selectionFirst in [true, false] {
            for tool in [EditorInteraction.Tool.rectangle, .rounded, .circle, .ellipse, .mask, .mosaic, .crop] {
                let f = try Fixture(); defer { f.remove() }
                let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
                let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
                let interaction = EditorInteraction(session: session, defaults: f.defaults)
                XCTAssertEqual(interaction.tool, .none)
                if !selectionFirst { interaction.chooseTool(tool) }
                interaction.begin(CGPoint(x: 10, y: 20), shift: false)
                interaction.end(CGPoint(x: 60, y: 80))
                if selectionFirst {
                    XCTAssertEqual(session.draft, EditState())
                    XCTAssertFalse(session.canUndo)
                    XCTAssertEqual(interaction.selectionSizeLabel, "50 × 60 px")
                    interaction.chooseTool(tool)
                }
                if tool == .crop {
                    XCTAssertEqual(session.draft.crop, PixelCrop(x: 10, y: 20, width: 50, height: 60))
                } else {
                    XCTAssertEqual(session.draft.objects.count, 1)
                    XCTAssertEqual(session.draft.objects[0].bounds.width, 50)
                    XCTAssertEqual(session.draft.objects[0].bounds.height, tool == .circle ? 50 : 60)
                }
                let applied = session.draft
                if selectionFirst {
                    interaction.chooseTool(tool)
                    XCTAssertEqual(session.draft, applied, "No duplicate edit without a new range")
                }
                interaction.undo()
                XCTAssertEqual(session.draft, EditState())
                interaction.redo()
                XCTAssertEqual(session.draft, applied)
                await session.waitUntilIdle()
                let reopened = EditorInteraction(session: session, defaults: f.defaults)
                XCTAssertEqual(reopened.tool, .none)
            }
        }
    }

    func testSeamlessToolSwitchingAndRepeatedMosaic() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.begin(CGPoint(x: 10, y: 10), shift: false)
        interaction.end(CGPoint(x: 30, y: 30))
        XCTAssertEqual(session.draft, EditState())
        interaction.chooseTool(.mosaic)
        XCTAssertEqual(interaction.tool, .mosaic)
        XCTAssertNil(interaction.pendingBounds)
        let first = session.draft.objects[0]
        interaction.begin(CGPoint(x: 40, y: 40), shift: false)
        interaction.end(CGPoint(x: 60, y: 60))
        XCTAssertEqual(session.draft.objects.count, 2)
        XCTAssertEqual(interaction.tool, .mosaic)
        let mosaics = session.draft
        interaction.chooseTool(.mask)
        XCTAssertEqual(interaction.tool, .mask)
        XCTAssertEqual(session.draft, mosaics)
        XCTAssertTrue(interaction.selected.isEmpty)
        interaction.begin(CGPoint(x: 70, y: 70), shift: false)
        interaction.end(CGPoint(x: 90, y: 90))
        XCTAssertEqual(session.draft.objects.count, 3)
        XCTAssertEqual(session.draft.objects[0], first)
        interaction.chooseTool(.mask)
        XCTAssertEqual(interaction.tool, .none)
        let applied = session.draft
        interaction.begin(CGPoint(x: 5, y: 5), shift: false)
        interaction.end(CGPoint(x: 15, y: 15))
        XCTAssertEqual(session.draft, applied)
        interaction.chooseTool(.rectangle)
        XCTAssertEqual(session.draft.objects.count, 4)
        XCTAssertEqual(interaction.tool, .rectangle)
        interaction.undo()
        XCTAssertEqual(session.draft, applied)
        interaction.redo()
        XCTAssertEqual(session.draft.objects.count, 4)
        await session.waitUntilIdle()
    }

    func testFreshCaptureReusesPixelsButEditedHistoryRendersItsEdits() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let image = try RasterImageDecoder.decode(f.original)
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports,
            settings: f.settings, initialPreview: image)
        XCTAssertTrue(session.preview === image)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.tool = .crop
        interaction.begin(CGPoint(x: 10, y: 10), shift: false)
        interaction.end(CGPoint(x: 40, y: 50))
        await session.waitUntilIdle()
        let reopened = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports,
            settings: f.settings, initialPreview: image)
        XCTAssertEqual(reopened.preview?.width, 30)
        XCTAssertEqual(reopened.preview?.height, 40)
        XCTAssertFalse(reopened.preview === image)
    }

    func testColoredImageBorderRendersAndSupportsUndoAndLegacyData() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.tool = .imageBorder
        interaction.borderColor = RGBColor(red: 1, green: 0.5, blue: 0)
        interaction.borderWidth = 4
        interaction.setBorder(enabled: true)
        let framed = session.draft
        interaction.begin(CGPoint(x: 10, y: 10), shift: false)
        interaction.end(CGPoint(x: 30, y: 30))
        XCTAssertEqual(session.draft, framed, "The whole-image border tool does not draw local rectangles")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: interaction.imageDataForSaveAs(jpegQuality: 0.9)))
        var components = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&components, atX: 0, y: 50)
        XCTAssertEqual(Array(components.prefix(3)), [255, 128, 0])
        interaction.undo()
        XCTAssertNil(session.draft.border)
        interaction.redo()
        XCTAssertEqual(session.draft, framed)
        await session.waitUntilIdle()
        let stored = try await f.store.load(id: doc.documentID)
        XCTAssertEqual(stored.document.edits, framed)
        let legacy = try JSONDecoder().decode(ImageBorder.self, from: Data("{\"brightness\":0.4,\"width\":3}".utf8))
        XCTAssertEqual(legacy.resolvedColor, RGBColor(red: 0.4, green: 0.4, blue: 0.4))
        XCTAssertThrowsError(try EditState(border: ImageBorder(color: RGBColor(red: .nan, green: 0, blue: 0), width: 1)).validate(pixelSize: doc.pixelSize))
    }

    func testMaskColorChangesSupportUndoAndPersistence() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.tool = .mask
        interaction.begin(CGPoint(x: 10, y: 10), shift: false)
        interaction.end(CGPoint(x: 40, y: 40))
        let gray = session.draft
        interaction.selectAll()
        let orange = RGBColor(red: 1, green: 0.5, blue: 0)
        interaction.maskColor = orange
        interaction.commitAttributes(.mask)
        XCTAssertEqual(session.draft.objects[0].style, .colorMask(color: orange))
        interaction.undo()
        XCTAssertEqual(session.draft, gray)
        interaction.redo()
        await session.waitUntilIdle()
        let stored = try await f.store.load(id: doc.documentID)
        XCTAssertEqual(stored.document.edits.objects[0].style, .colorMask(color: orange))
    }

    func testImageBorderRendersCroppedEdgesPersistsAndSupportsUndo() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.tool = .crop
        interaction.borderBrightness = 0.4; interaction.borderWidth = 3
        interaction.setBorder(enabled: true)
        interaction.begin(CGPoint(x: 10, y: 20), shift: false)
        interaction.end(CGPoint(x: 40, y: 60))
        let data = try interaction.imageDataForSaveAs(jpegQuality: 0.9)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        try interaction.copyImage(to: board)
        XCTAssertEqual(board.data(forType: .png), data, "Copy includes the current crop and border")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 30); XCTAssertEqual(bitmap.pixelsHigh, 40)
        for point in [(0, 0), (2, 20), (27, 20), (15, 2), (15, 37)] {
            var components = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&components, atX: point.0, y: point.1)
            XCTAssertEqual(Array(components.prefix(3)), [102, 102, 102])
        }
        let plain = try NSBitmapImageRep(data: RasterImageCodec.encode(session.renderDraft(EditState(crop: session.draft.crop)), format: .png))
        XCTAssertEqual(bitmap.colorAt(x: 3, y: 3), plain?.colorAt(x: 3, y: 3))
        interaction.setBorder(enabled: false)
        XCTAssertNil(session.draft.border)
        interaction.undo()
        XCTAssertEqual(session.draft.border, ImageBorder(brightness: 0.4, width: 3))
        await session.waitUntilIdle()
        let stored = try await f.store.load(id: doc.documentID)
        XCTAssertEqual(stored.document.edits.border, session.draft.border)
        XCTAssertEqual(stored.originalData, f.original)
        let legacy = try JSONDecoder().decode(EditState.self, from: Data("{\"objects\":[]}".utf8))
        XCTAssertNil(legacy.border)
        XCTAssertThrowsError(try EditState(border: ImageBorder(brightness: .nan, width: 1)).validate(pixelSize: doc.pixelSize))
    }

    func testSaveAsAndCopyUseCurrentDraftInsteadOfOlderPreview() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.tool = .crop
        interaction.begin(CGPoint(x: 10, y: 10), shift: false)
        interaction.end(CGPoint(x: 80, y: 80))
        await session.waitUntilIdle()
        interaction.begin(CGPoint(x: 20, y: 20), shift: false)
        interaction.drag(CGPoint(x: 40, y: 50))
        XCTAssertNotEqual(interaction.previewEdits, session.draft)
        let saved = try XCTUnwrap(NSBitmapImageRep(data: interaction.imageDataForSaveAs(jpegQuality: 0.9)))
        XCTAssertEqual(saved.pixelsWide, 20)
        XCTAssertEqual(saved.pixelsHigh, 30)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        try interaction.copyImage(to: board)
        let copied = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(board.data(forType: .png))))
        XCTAssertEqual(copied.pixelsWide, 20)
        XCTAssertEqual(copied.pixelsHigh, 30)
        interaction.undo()
        _ = await f.exports.waitForCurrentWorkers()
    }

    func testEveryDrawingToolCropAttributesAndDeleteUndoRedoAsOperations() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        var states = [session.draft]
        for tool in [EditorInteraction.Tool.rectangle, .rounded, .circle, .ellipse, .mask, .mosaic, .crop] {
            interaction.tool = tool
            interaction.begin(CGPoint(x: 10, y: 10), shift: false)
            interaction.drag(CGPoint(x: 25, y: 25))
            interaction.end(CGPoint(x: 70, y: 70))
            states.append(session.draft)
        }
        interaction.resetCrop(); states.append(session.draft)
        interaction.selectAll()
        interaction.color = RGBColor(red: 0, green: 1, blue: 0)
        interaction.commitAttributes(.outline); states.append(session.draft)
        interaction.brightness = 0.7
        interaction.commitAttributes(.mask); states.append(session.draft)
        interaction.blockSize = 9
        interaction.commitAttributes(.mosaic); states.append(session.draft)
        interaction.tool = .select
        interaction.begin(CGPoint(x: 20, y: 20), shift: false)
        interaction.end(CGPoint(x: 22, y: 23)); states.append(session.draft)
        interaction.selectAll(); interaction.deleteSelection(); states.append(session.draft)
        for state in states.dropLast().reversed() {
            XCTAssertTrue(session.canUndo)
            interaction.undo()
            XCTAssertEqual(session.draft, state)
        }
        XCTAssertFalse(session.canUndo)
        for state in states.dropFirst() {
            XCTAssertTrue(session.canRedo)
            interaction.redo()
            XCTAssertEqual(session.draft, state)
        }
        XCTAssertFalse(session.canRedo)
        interaction.undo()
        interaction.tool = .crop
        interaction.begin(CGPoint(x: 5, y: 5), shift: false)
        interaction.end(CGPoint(x: 40, y: 40))
        XCTAssertFalse(session.canRedo, "A new edit must invalidate redo")
        await session.waitUntilIdle()
        XCTAssertEqual(session.persisted.edits, session.draft)
        let stored = try await f.store.load(id: doc.documentID)
        XCTAssertEqual(stored.originalData, f.original)
        _ = await f.exports.waitForCurrentWorkers()
    }

    func testPixelDimensionsForEveryDrawingToolAndReverseDrag() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        for tool in EditorInteraction.Tool.allCases where tool != .none && tool != .select && tool != .imageBorder {
            interaction.tool = tool
            interaction.begin(CGPoint(x: 50.5, y: 70.5), shift: false)
            interaction.drag(CGPoint(x: 10.2, y: 20.8))
            let expected = tool == .circle ? "41 × 41 px" : "41 × 51 px"
            XCTAssertEqual(interaction.selectionSizeLabel, expected, tool.rawValue)
            interaction.end(CGPoint(x: 10.2, y: 20.8))
            XCTAssertEqual(interaction.selectionSizeLabel, expected, tool.rawValue)
            interaction.undo()
        }
        await session.waitUntilIdle()
    }

    func testAllEditorToolsHaveAvailableDistinctIcons() {
        let tools = EditorInteraction.Tool.allCases.filter { $0 != .none }
        XCTAssertEqual(Set(tools.map(\.symbol)).count, tools.count)
        for tool in tools {
            XCTAssertNotNil(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil), tool.rawValue)
        }
    }

    func testNewEditorStartsWithoutToolAndRequiresCropSelection() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        XCTAssertEqual(interaction.tool, .none)
        interaction.begin(CGPoint(x: 10, y: 20), shift: false)
        interaction.end(CGPoint(x: 60, y: 80))
        XCTAssertEqual(session.draft, EditState())
        XCTAssertFalse(session.canUndo)
        interaction.tool = .crop
        interaction.begin(CGPoint(x: 10, y: 20), shift: false)
        interaction.end(CGPoint(x: 60, y: 80))
        await session.waitUntilIdle()
        XCTAssertEqual(session.persisted.edits.crop, PixelCrop(x: 10, y: 20, width: 50, height: 60))
        XCTAssertEqual(interaction.preview?.width, 50)
        XCTAssertEqual(interaction.preview?.height, 60)
        interaction.resetCrop()
        await session.waitUntilIdle()
        XCTAssertNil(session.persisted.edits.crop)
        _ = await f.exports.waitForCurrentWorkers()
    }

    func testDragPersistsOnlyOnEndMultiSelectMoveDeleteAndOriginalIsImmutable() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: document.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.tool = .rectangle
        interaction.begin(CGPoint(x: 10, y: 10), shift: false)
        interaction.drag(CGPoint(x: 30, y: 40))
        await session.waitUntilIdle()
        XCTAssertEqual(session.persisted.revision, 0)
        XCTAssertTrue(session.hasUnpersistedChanges)
        interaction.end(CGPoint(x: 30, y: 40))
        await session.waitUntilIdle()
        XCTAssertEqual(session.persisted.revision, 1)
        interaction.tool = .mask
        interaction.begin(CGPoint(x: 50, y: 50), shift: false)
        interaction.end(CGPoint(x: 70, y: 70))
        await session.waitUntilIdle()
        XCTAssertEqual(session.persisted.edits.objects.count, 2)
        interaction.tool = .select; interaction.selectAll()
        interaction.begin(CGPoint(x: 15, y: 15), shift: false)
        interaction.end(CGPoint(x: 20, y: 22))
        await session.waitUntilIdle()
        XCTAssertEqual(session.persisted.edits.objects.map(\.bounds.x), [15,55])
        XCTAssertEqual(session.persisted.edits.objects.map(\.bounds.y), [17,57])
        interaction.brightness = 0.8; interaction.commitAttributes(.mask)
        await session.waitUntilIdle()
        guard case .grayMask(let brightness) = session.persisted.edits.objects[1].style else { return XCTFail("Wrong style") }
        XCTAssertEqual(brightness, 0.8)
        guard case .outline = session.persisted.edits.objects[0].style else { return XCTFail("Changed other kind") }
        interaction.deleteSelection(); await session.waitUntilIdle()
        XCTAssertTrue(session.persisted.edits.objects.isEmpty)
        let loaded = try await f.store.load(id: document.documentID)
        XCTAssertEqual(loaded.originalData, f.original)
        _ = await f.exports.waitForCurrentWorkers()
    }

    func testResizeCircleCropPixelLabelPreferencesAndFreeze() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.tool = .circle; interaction.lineWidth = 5; interaction.commitAttributes(.outline)
        interaction.begin(CGPoint(x: 10, y: 10), shift: false); interaction.end(CGPoint(x: 40, y: 50))
        await session.waitUntilIdle()
        XCTAssertEqual(session.draft.objects[0].bounds.width, 30)
        XCTAssertEqual(session.draft.objects[0].bounds.height, 30)
        interaction.tool = .select
        interaction.begin(CGPoint(x: 40, y: 40), shift: false); interaction.end(CGPoint(x: 60, y: 70))
        await session.waitUntilIdle()
        XCTAssertEqual(session.draft.objects[0].bounds.width, 50)
        XCTAssertEqual(session.draft.objects[0].bounds.height, 50)
        interaction.tool = .crop
        interaction.begin(CGPoint(x: 2.5, y: 3.5), shift: false); interaction.drag(CGPoint(x: 20.5, y: 30.5))
        XCTAssertEqual(interaction.selectionSizeLabel, "19 × 28 px")
        interaction.end(CGPoint(x: 20.5, y: 30.5)); await session.waitUntilIdle()
        XCTAssertEqual(interaction.preview?.width, 19); XCTAssertEqual(interaction.preview?.height, 28)
        let restored = EditorInteraction(session: session, defaults: f.defaults)
        XCTAssertEqual(restored.lineWidth, 5)
        let before = session.draft
        session.beginTermination()
        interaction.resetCrop(); interaction.deleteSelection()
        XCTAssertEqual(session.draft, before)
        _ = await f.exports.waitForCurrentWorkers()
    }

    func testSavedMosaicBlockSizeOutsideSliderRangeFallsBackToDefault() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let session = try await EditorSession.open(documentID: doc.documentID, store: f.store, exports: f.exports, settings: f.settings)
        for (saved, expected) in [(1.0, 12.0), (60, 12), (2, 2), (40, 40)] {
            f.defaults.set(saved, forKey: "getGamen.edit.blockSize")
            XCTAssertEqual(EditorInteraction(session: session, defaults: f.defaults).blockSize, expected, "saved \(saved)")
        }
        // A mosaic made outside the editor (CLI allows 1...100) must not carry 60 into the next new mosaic.
        let interaction = EditorInteraction(session: session, defaults: f.defaults)
        interaction.tool = .mosaic; interaction.blockSize = 60
        interaction.begin(CGPoint(x: 10, y: 10), shift: false); interaction.end(CGPoint(x: 50, y: 50))
        await session.waitUntilIdle()
        XCTAssertEqual(session.draft.objects.last?.style, .mosaic(blockSize: 60))
        interaction.tool = .select; interaction.blockSize = 12
        interaction.begin(CGPoint(x: 30, y: 30), shift: false); interaction.end(CGPoint(x: 30, y: 30))
        await session.waitUntilIdle()
        XCTAssertEqual(interaction.blockSize, 40)
        XCTAssertEqual(session.draft.objects.last?.style, .mosaic(blockSize: 60))
        _ = await f.exports.waitForCurrentWorkers()
    }

    func testTypedMosaicBlockSizeIsClampedToSliderRange() {
        let rule = LineWidthRule.mosaic
        XCTAssertEqual(rule.range, EditorInteraction.blockSizeRange)
        for (typed, expected) in [("25", 25.0), ("100", 40), ("0", 2), ("２５", 25), ("12.6", 13)] {
            XCTAssertEqual(rule.value(from: typed), expected, typed)
        }
        XCTAssertNil(rule.value(from: "abc"))
        XCTAssertEqual(rule.text(for: 25), "25")
    }

    func testImportAcceptedBeforeFreezeIsDrainedAndReportsUnopenedEditor() async throws {
        let f = try Fixture(); defer { f.remove() }
        let editors = EditorWindowCoordinator(store: f.store, exports: f.exports, settings: f.settings)
        let library = LibraryController(store: f.store, editors: editors, settings: f.settings)
        let input = f.root.appendingPathComponent("source.png"); try f.original.write(to: input)
        library.importImages([input])
        XCTAssertTrue(library.busy)
        library.freeze(); editors.beginTermination()
        await library.waitUntilIdle()
        XCTAssertFalse(library.busy)
        let ids = try await f.store.documentIDs()
        XCTAssertEqual(ids.count, 1)
        let loaded = try await f.store.load(id: XCTUnwrap(ids.first))
        XCTAssertEqual(loaded.originalData, f.original)
        XCTAssertFalse(library.failures.isEmpty, "An editor that cannot open during termination is reported")
    }

    func testDeleteInvalidatesPendingOpenEvenWhenItsContinuationResumesLate() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let gate = AsyncGate(), entered = XCTestExpectation(description: "load entered")
        let editors = EditorWindowCoordinator(store: f.store, exports: f.exports, settings: f.settings,
                                             beforeLoad: { entered.fulfill(); await gate.wait() })
        let opening = Task { try await editors.openEditor(documentID: doc.documentID) }
        await fulfillment(of: [entered], timeout: 2)
        let reserved = XCTestExpectation(description: "deletion reserved")
        let deleting = Task { try await editors.deleteDocument(doc.documentID, onReserved: { reserved.fulfill() }) }
        await fulfillment(of: [reserved], timeout: 2)
        gate.release()
        try await deleting.value
        do { _ = try await opening.value; XCTFail("Deleted document was presented") }
        catch { XCTAssertEqual(error as? EditorWindowError, .deletionInProgress) }
        XCTAssertNil(editors.window(for: doc.documentID))
        let ids = try await f.store.documentIDs(); XCTAssertTrue(ids.isEmpty)
    }

    func testDeleteRefusesDirtyEditorAndRestoresEditingAfterRefusal() async throws {
        let f = try Fixture(); defer { f.remove() }
        let doc = try await f.store.create(original: f.original, pixelSize: PixelSize(width: 100, height: 100))
        let editors = EditorWindowCoordinator(store: f.store, exports: f.exports, settings: f.settings)
        let session = try await editors.openEditor(documentID: doc.documentID)
        defer { editors.window(for: doc.documentID)?.close() }
        let draft = EditState(crop: PixelCrop(x: 3, y: 4, width: 30, height: 40))
        session.setDraft(draft)
        do { try await editors.deleteDocument(doc.documentID); XCTFail("Deleted unsaved edits") }
        catch { XCTAssertEqual(error as? EditorWindowError, .unsavedChanges) }
        XCTAssertEqual(session.draft, draft)
        XCTAssertFalse(session.isTerminationPending, "Refused deletion must restore editing")
        XCTAssertNotNil(editors.window(for: doc.documentID))
        let retained = try await f.store.load(id: doc.documentID)
        XCTAssertEqual(retained.originalData, f.original)
        XCTAssertEqual(retained.document.revision, 0)
        session.commitDraft(); session.requestExport(); await session.waitUntilIdle()
        _ = await f.exports.waitForCurrentWorkers()
        XCTAssertFalse(session.hasUnpersistedChanges)
        let saved = try await f.store.load(id: doc.documentID)
        XCTAssertEqual(saved.document.edits, draft)
        XCTAssertEqual(saved.document.revision, 1)
        let output = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: f.root.appendingPathComponent("output"), includingPropertiesForKeys: nil).first { $0.pathExtension == "png" })
        let outputBytes = try Data(contentsOf: output)
        try await editors.deleteDocument(doc.documentID)
        XCTAssertNil(editors.window(for: doc.documentID))
        let remaining = try await f.store.documentIDs(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try Data(contentsOf: output), outputBytes)
    }

    func testFrozenLibraryRejectsImportAndCanResume() async throws {
        let f = try Fixture(); defer { f.remove() }
        let editors = EditorWindowCoordinator(store: f.store, exports: f.exports, settings: f.settings)
        let library = LibraryController(store: f.store, editors: editors, settings: f.settings)
        let input = f.root.appendingPathComponent("source.png"); try f.original.write(to: input)
        library.freeze()
        library.importImages([input])
        await library.waitUntilIdle()
        XCTAssertFalse(library.busy)
        let rejected = try await f.store.documentIDs(); XCTAssertTrue(rejected.isEmpty)
        library.resume()
        library.importImages([input])
        await library.waitUntilIdle()
        XCTAssertFalse(library.busy)
        XCTAssertTrue(library.failures.isEmpty)
        let ids = try await f.store.documentIDs(); XCTAssertEqual(ids.count, 1)
        for id in ids { editors.window(for: id)?.close() }
        await editors.closeDeletion?.value
    }

    @MainActor private final class AsyncGate {
        var continuation: CheckedContinuation<Void,Never>?
        var released = false
        func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor
    private struct Fixture {
        let root: URL, defaults: UserDefaults, suite: String
        let store: DocumentStore, exports: AutomaticExportCoordinator, settings: ExportSettings
        let original: Data
        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-integration-\(UUID())")
            suite = "getGamen.test.\(UUID())"; defaults = UserDefaults(suiteName: suite)!
            store = try DocumentStore(root: root.appendingPathComponent("history"))
            exports = try AutomaticExportCoordinator(receiptsRoot: root.appendingPathComponent("receipts"))
            settings = ExportSettings(defaults: defaults)
            let output = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try settings.setDestinationFolder(output)
            let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 100,height: 100))
            original = try RasterImageCodec.encode(XCTUnwrap(context.makeImage()), format: .png)
        }
        func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
}
