import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Observation
import XCTest
@testable import GetGamen
@testable import GetGamenCore

final class EditorSessionTests: XCTestCase {
    func testLineWidthRuleReadsTypedTextAndRoundsToItsStep() {
        let outline = LineWidthRule.outline
        XCTAssertEqual(outline.value(from: "0.5"), 0.5)
        XCTAssertEqual(outline.value(from: " ２px "), 2)
        XCTAssertEqual(outline.value(from: "３．５ＰＸ"), 3.5)
        XCTAssertEqual(outline.value(from: "0.55"), 0.6)
        XCTAssertEqual(outline.value(from: "0.1"), 0.5, "Below the range rounds up to the minimum")
        XCTAssertEqual(outline.value(from: "500"), 100, "Above the range rounds down to the maximum")
        for text in ["", "abc", "px", "nan", "inf"] { XCTAssertNil(outline.value(from: text), text) }
        XCTAssertEqual(outline.text(for: 3.47), "3.5")
        XCTAssertEqual(outline.text(for: 12), "12")
        let border = LineWidthRule.imageBorder
        XCTAssertEqual(border.value(from: "2.6"), 3)
        XCTAssertEqual(border.value(from: "0.5"), 1)
        XCTAssertEqual(border.text(for: 4), "4")
        for rule in [outline, border] {
            XCTAssertTrue(rule.presets.allSatisfy { rule.range.contains($0) && rule.value(from: rule.text(for: $0)) == $0 })
        }
    }

    @MainActor
    func testCaptureFileSurvivesEditsUndoFormatChangesAndSaveAs() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let document = try await f.create()
        let session = try await f.open(document)
        session.requestCaptureExport(using: f.settings.snapshot)
        try await idle(session)
        let state = try await settle(f, document.documentID)
        guard case .saved(_, 0, let originalURL) = state else { return XCTFail("Capture was not saved") }
        let originalBytes = try Data(contentsOf: originalURL)
        session.setDraft(EditState(crop: PixelCrop(x: 0, y: 0, width: 1, height: 1)))
        session.commitDraft()
        try await idle(session)
        session.undoEdit(); session.redoEdit()
        session.commitFormat(.jpeg)
        try session.commitJPEGQuality(0.4)
        try await idle(session)
        _ = await f.exports.waitForCurrentWorkers()
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        let editedURL = f.a.appendingPathComponent("edited.jpg")
        try EditorInteraction(session: session).imageDataForSaveAs(jpegQuality: 0.4).write(to: editedURL)
        let edited = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: editedURL)))
        XCTAssertEqual(edited.pixelsWide, 1)
        XCTAssertEqual(edited.pixelsHigh, 1)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        // Retrying capture output after editing must still encode the captured original.
        session.retryExport()
        try await idle(session)
        _ = try await settle(f, document.documentID)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(session.preview?.width, 1)
        let jpegReceipt = try await f.exports.existing(documentID: document.documentID, slot: .jpg)
        XCTAssertNil(jpegReceipt, "Changing Save As format must not automatically publish an image")
        f.settings.setFormat(.png)
        let reopened = try await f.open(document)
        reopened.retryExport()
        try await idle(reopened)
        _ = try await settle(f, document.documentID)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes,
                       "Reopening an editor must never retry with edited pixels")
    }

    @MainActor
    func testCopyFlattensUnsavedCropWithoutSavingOrChangingOriginal() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let session = try await f.open(document)
        let draft = EditState(crop: PixelCrop(x: 0, y: 0, width: 1, height: 1))
        session.setDraft(draft)
        let board = NSPasteboard(name: NSPasteboard.Name("getGamen.test.\(UUID())"))
        defer { board.releaseGlobally() }
        let interaction = EditorInteraction(session: session)
        try interaction.copyImage(to: board)
        let savedData = try interaction.imageDataForSaveAs(jpegQuality: 0.9)
        let savedImage = try XCTUnwrap(NSBitmapImageRep(data: savedData))
        XCTAssertEqual(savedImage.pixelsWide, 1)
        XCTAssertEqual(savedImage.pixelsHigh, 1)
        let data = try XCTUnwrap(board.data(forType: .png))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(image.pixelsWide, 1)
        XCTAssertEqual(image.pixelsHigh, 1)
        XCTAssertNotNil(board.data(forType: .tiff))
        XCTAssertEqual(session.draft, draft)
        XCTAssertTrue(session.hasUnpersistedChanges)
        let stored = try await f.store.load(id: document.documentID)
        XCTAssertEqual(stored.document.revision, 0)
        XCTAssertEqual(stored.originalData, f.original)
    }

    @MainActor
    func testTerminationFreezesAllMutatorsAndResumesWithoutDiscard() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let session = try await f.open(document)
        let dirty = EditState(crop: PixelCrop(x: 0, y: 0, width: 1, height: 1))
        session.setDraft(dirty)
        let settings = f.settings.snapshot
        session.beginTermination()
        session.setDraft(EditState())
        session.commitDraft()
        session.commitFormat(.jpeg)
        try session.commitJPEGQuality(0.1)
        session.requestExport()
        session.retryPending()
        await session.waitUntilIdle()
        XCTAssertEqual(session.draft, dirty)
        XCTAssertTrue(session.hasUnpersistedChanges)
        XCTAssertEqual(session.persisted.revision, 0)
        XCTAssertEqual(f.settings.snapshot, settings)
        session.endTermination()
        session.setDraft(EditState())
        XCTAssertFalse(session.hasUnpersistedChanges)
    }

    @MainActor
    func testTerminationDrainsAlreadyAcceptedSaveAndExport() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let document = try await f.create()
        let gate = Gate<Void>(); defer { gate.fail() }
        let session = try await f.open(document, beforeSave: { try await gate.run() })
        session.commitDraft()
        session.requestExport()
        try await gate.waitStarted()
        session.beginTermination()
        XCTAssertTrue(session.isProcessing)
        gate.finish(.success(()))
        await session.waitUntilIdle()
        let statuses = await f.exports.waitForCurrentWorkers()
        XCTAssertEqual(session.persisted.revision, 1)
        XCTAssertFalse(session.hasUnpersistedChanges)
        guard case .saved = statuses[document.documentID] else { return XCTFail("Accepted export must finish") }
    }

    @MainActor
    func testOpenDoesNotSaveExportOrCreateDefaultAndKeepsOriginalBytes() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let session = try await f.open(document)
        try await idle(session)
        let loaded = try await f.store.load(id: document.documentID)
        let status = await f.exports.status(documentID: document.documentID)
        let existing = try await f.exports.existing(documentID: document.documentID, slot: .png)
        XCTAssertEqual(loaded.document.revision, 0)
        XCTAssertEqual(loaded.originalData, f.original)
        XCTAssertEqual(session.persisted, document)
        XCTAssertEqual(session.preview?.width, 2)
        XCTAssertEqual(session.previewEdits, EditState())
        XCTAssertFalse(session.hasUnpersistedChanges)
        XCTAssertNil(session.issue); XCTAssertEqual(status, .idle); XCTAssertNil(existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.defaultFolder.path))
    }

    @MainActor
    func testTwoCommitsSerializeRealSavesAndExportOnlyPersistedRevisions() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let document = try await f.create()
        let first = Gate<Void>(); let second = Gate<Void>()
        defer { first.fail(); second.fail() }
        var saveEntries = 0
        var exported: [UInt64] = []
        let session = try await f.open(document, beforeSave: {
            saveEntries += 1
            if saveEntries == 1 { try await first.run() }
            else if saveEntries == 2 { try await second.run() }
            else { XCTFail("Unexpected save") }
        }, beforeExportSubmit: { request in
            let stored = try await f.store.load(id: request.documentID)
            XCTAssertEqual(request.revision, stored.document.revision)
            XCTAssertEqual(request.createdAt, stored.document.createdAt)
            XCTAssertEqual(stored.originalData, f.original)
            let encoded = try await request.encode()
            XCTAssertEqual(try Self.decodedPixels(encoded), [UInt8(255), 0, 0, 255, 0, 255, 0, 255,
                                                            0, 0, 255, 255, 255, 255, 0, 255])
            exported.append(request.revision)
        })
        session.commitDraft(); session.requestExport(); session.commitDraft(); session.requestExport()
        try await first.waitStarted()
        let before = try await f.store.load(id: document.documentID)
        let initialStatus = await f.exports.status(documentID: document.documentID)
        XCTAssertEqual(before.document.revision, 0); XCTAssertEqual(initialStatus, .idle)
        XCTAssertEqual(saveEntries, 1); XCTAssertTrue(exported.isEmpty)
        first.finish(.success(()))
        try await second.waitStarted()
        let intermediate = try await f.store.load(id: document.documentID)
        XCTAssertEqual(intermediate.document.revision, 1)
        XCTAssertEqual(exported, [1])
        second.finish(.success(()))
        try await idle(session)
        let saved = try await settle(f, document.documentID)
        let final = try await f.store.load(id: document.documentID)
        let receipt = try await f.exports.existing(documentID: document.documentID, slot: .png)
        XCTAssertEqual(final.document.revision, 2)
        XCTAssertEqual(session.persisted.revision, 2)
        XCTAssertEqual(exported, [1, 2])
        XCTAssertEqual(receipt?.stamp.documentRevision, 2)
        XCTAssertEqual(final.originalData, f.original)
        XCTAssertFalse(session.hasUnpersistedChanges)
        try await observed(session) { $0 == saved }
    }

    @MainActor
    func testActualRevisionConflictBlocksRetryWithoutRebasing() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let document = try await f.create()
        let gate = Gate<Void>(); defer { gate.fail() }
        var saves = 0; var exports = 0
        let session = try await f.open(document, beforeSave: {
            saves += 1
            if saves == 1 { try await gate.run() }
        }, beforeExportSubmit: { _ in exports += 1 })
        session.commitDraft()
        try await gate.waitStarted()
        let external = try await f.store.save(id: document.documentID, edits: EditState(), expectedRevision: 0)
        XCTAssertEqual(external.revision, 1)
        gate.finish(.success(()))
        try await idle(session)
        assertConflict(session)
        XCTAssertEqual(session.persisted.revision, 0)
        XCTAssertTrue(session.hasUnpersistedChanges); XCTAssertEqual(exports, 0)
        session.retryPending()
        try await idle(session)
        assertConflict(session)
        let stored = try await f.store.load(id: document.documentID)
        XCTAssertEqual(stored.document.revision, 1)
        XCTAssertEqual(stored.originalData, f.original)
        XCTAssertEqual(saves, 2); XCTAssertEqual(exports, 0)
        let status = await f.exports.status(documentID: document.documentID)
        XCTAssertEqual(status, .idle)
    }

    @MainActor
    func testBlockedHeadAndQueuedFormatKeepOriginalSettingsOnRetryAndPreserveNewerDraft() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let document = try await f.create()
        var failing = true; var saves = 0
        var requests: [(ExportSlot, String, UInt64, UInt8)] = []
        let session = try await f.open(document, beforeSave: {
            saves += 1
            if failing { throw Injected.save }
        }, beforeExportSubmit: { request in
            let encoded = try await request.encode()
            XCTAssertGreaterThan(encoded.count, 25)
            guard encoded.count > 25 else { throw Injected.fixture }
            requests.append((request.slot, request.destinationFolder.path, request.revision, encoded[25]))
        })
        session.commitDraft()
        session.requestExport()
        try await idle(session)
        if case .persistence(let error)? = session.issue { XCTAssertEqual(error as? Injected, .save) }
        else { XCTFail("Missing save failure") }
        XCTAssertTrue(session.hasUnpersistedChanges)
        let newerDraft = mask()
        session.setDraft(newerDraft)
        try f.settings.setDestinationFolder(f.b)
        session.commitFormat(.png8)
        session.requestExport()
        try await idle(session)
        XCTAssertEqual(saves, 1, "Enqueue while blocked must not retry automatically")
        XCTAssertTrue(requests.isEmpty)
        failing = false
        session.retryPending()
        try await idle(session)
        _ = try await settle(f, document.documentID)
        XCTAssertEqual(saves, 2); XCTAssertEqual(requests.count, 2)
        guard requests.count == 2 else { return }
        XCTAssertEqual(requests[0].0, .png); XCTAssertEqual(requests[0].1, f.a.path)
        XCTAssertEqual(requests[0].2, 1); XCTAssertNotEqual(requests[0].3, 3)
        XCTAssertEqual(requests[1].0, .png); XCTAssertEqual(requests[1].1, f.b.path)
        XCTAssertEqual(requests[1].2, 1); XCTAssertEqual(requests[1].3, 3, "Actual encoded PNG8 must be indexed")
        XCTAssertEqual(session.draft, newerDraft)
        XCTAssertEqual(session.persisted.edits, EditState())
        XCTAssertEqual(session.previewEdits, EditState())
        XCTAssertTrue(session.hasUnpersistedChanges)
    }

    @MainActor
    func testActualWriterFailureAfterDestinationResolutionPreservesOldOutputAndSavedDocument() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let document = try await f.create()
        var removeB = false
        let session = try await f.open(document, beforeExportSubmit: { request in
            if removeB {
                XCTAssertEqual(request.destinationFolder.path, f.b.path)
                try FileManager.default.removeItem(at: f.b)
            }
        })
        session.requestExport()
        try await idle(session)
        let first = try await settle(f, document.documentID)
        guard case .saved(_, 0, let oldURL) = first else { return XCTFail("Initial publication failed") }
        let oldBytes = try Data(contentsOf: oldURL)
        let oldReceipt = try await f.exports.existing(documentID: document.documentID, slot: .png)
        try f.settings.setDestinationFolder(f.b)
        removeB = true
        session.commitDraft()
        session.requestExport()
        try await idle(session)
        let failure = try await settle(f, document.documentID)
        guard case .failed(_, 1, _) = failure else { return XCTFail("Expected actual writer destination failure") }
        try await observed(session) { $0 == failure }
        let stored = try await f.store.load(id: document.documentID)
        let retained = try await f.exports.existing(documentID: document.documentID, slot: .png)
        XCTAssertEqual(stored.document.revision, 1)
        XCTAssertEqual(stored.originalData, f.original)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        XCTAssertEqual(retained, oldReceipt)
        XCTAssertEqual(session.persisted.revision, 1)
        XCTAssertFalse(session.hasUnpersistedChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.b.path))
    }

    @MainActor
    func testPersistedMaskRendersAndExportsOnlyRedactedPixels() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let document = try await f.create()
        let edited = try await f.store.save(id: document.documentID, edits: mask(), expectedRevision: 0)
        let session = try await f.open(edited)
        XCTAssertNotNil(session.preview)
        XCTAssertNil(session.issue)
        session.requestExport()
        try await idle(session)
        let state = try await settle(f, document.documentID)
        guard case .saved(_, _, let url) = state else { return XCTFail("Expected redacted export") }
        let bytes = try Self.decodedPixels(Data(contentsOf: url))
        XCTAssertEqual(Array(bytes.prefix(4)), [128, 128, 128, 255])
        let stored = try await f.store.load(id: document.documentID)
        XCTAssertEqual(stored.document, edited)
        XCTAssertEqual(stored.originalData, f.original)
    }

    @MainActor
    func testInvalidNewDraftKeepsOnlyIdentifiedPriorPreviewAndCannotSkipFailedHead() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let session = try await f.open(document)
        let prior = try XCTUnwrap(session.preview)
        session.setDraft(EditState(objects: [EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 1, height: 1), style: .grayMask(brightness: -1))])); session.commitDraft()
        try await idle(session)
        assertMaskFailure(session)
        XCTAssertTrue(session.preview === prior)
        XCTAssertEqual(session.previewEdits, EditState())
        XCTAssertEqual(session.persisted.revision, 0)
        XCTAssertTrue(session.hasUnpersistedChanges)
        session.setDraft(EditState()); session.requestExport(); session.retryPending()
        try await idle(session)
        assertMaskFailure(session)
        XCTAssertTrue(session.hasUnpersistedChanges, "Repairing draft does not discard the failed queued operation")
        let stored = try await f.store.load(id: document.documentID)
        let state = await f.exports.status(documentID: document.documentID)
        XCTAssertEqual(stored.document.revision, 0); XCTAssertEqual(state, .idle)
    }

    @MainActor
    func testFormatsRemainPerEditorAndPNG8SharesPNGSlotWhileJPEGUsesSeparateFile() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let first = try await f.create(); let second = try await f.create()
        let a = try await f.open(first); let b = try await f.open(second)
        a.requestExport()
        try await idle(a)
        let initial = try await settle(f, first.documentID)
        guard case .saved(_, _, let pngURL) = initial else { return XCTFail("PNG not saved") }
        a.commitFormat(.png8); a.requestExport()
        try await idle(a)
        _ = try await settle(f, first.documentID)
        let pngReceipt = try await f.exports.existing(documentID: first.documentID, slot: .png)
        XCTAssertNotEqual(pngReceipt?.url, pngURL)
        let indexed = try Data(contentsOf: XCTUnwrap(pngReceipt?.url))
        XCTAssertGreaterThan(indexed.count, 25)
        if indexed.count > 25 { XCTAssertEqual(indexed[25], 3) }
        XCTAssertEqual(a.format, .png8); XCTAssertEqual(b.format, .png)
        XCTAssertEqual(f.settings.snapshot.format, .png8)
        let secondStatus = await f.exports.status(documentID: second.documentID)
        XCTAssertEqual(secondStatus, .idle)
        let thirdDocument = try await f.create()
        let third = try await f.open(thirdDocument)
        XCTAssertEqual(third.format, .png8)
        a.commitFormat(.jpeg); a.requestExport()
        try await idle(a)
        _ = try await settle(f, first.documentID)
        let possibleJPEG = try await existing(f, first.documentID, .jpg)
        let jpeg = try XCTUnwrap(possibleJPEG)
        XCTAssertNotEqual(jpeg.url, pngURL)
        XCTAssertEqual(jpeg.url.pathExtension, "jpg")
        XCTAssertEqual(Array(try Data(contentsOf: jpeg.url).prefix(2)), [UInt8(0xff), UInt8(0xd8)])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(pngReceipt?.url)), indexed)
        XCTAssertEqual(a.persisted.revision, 0); XCTAssertEqual(b.format, .png)
    }

    @MainActor
    func testCaptureInitialSnapshotWinsAndEmptyRetryDoesNotEraseExportPreparationFailure() async throws {
        let f = try Fixture(); defer { f.remove() }
        let document = try await f.create()
        let initial = ExportSettingsSnapshot(format: .png8, jpegQuality: 0.2, destination: .configuredFolder(f.a))
        f.settings.setFormat(.jpeg); try f.settings.setDestinationFolder(f.b)
        let session = try await f.open(document, initialSettings: initial)
        XCTAssertEqual(session.format, .png8); XCTAssertEqual(f.settings.snapshot.format, .jpeg)
        session.requestExport(using: initial)
        try await idle(session)
        let saved = try await settle(f, document.documentID)
        guard case .saved(_, 0, let url) = saved else { return XCTFail("Initial snapshot not exported") }
        XCTAssertEqual(url.deletingLastPathComponent().path, f.a.path)
        let before = try Data(contentsOf: url)
        session.requestExport(using: ExportSettingsSnapshot(format: .png, jpegQuality: 0.9, destination: .invalidStoredFolder))
        try await idle(session)
        if case .exportPreparation(let error)? = session.issue { XCTAssertEqual(error as? ExportSettingsError, .invalidDestination) }
        else { XCTFail("Preparation error not surfaced") }
        session.retryPending()
        try await idle(session)
        if case .exportPreparation(_)? = session.issue {} else { XCTFail("Empty retry erased unresolved error") }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(session.persisted.revision, 0)
        XCTAssertFalse(session.hasUnpersistedChanges)
        session.requestExport(using: initial)
        try await idle(session)
        let recovered = try await settle(f, document.documentID)
        guard case .saved(_, 0, let recoveredURL) = recovered else { return XCTFail("Explicit valid export did not recover") }
        XCTAssertNotEqual(recoveredURL, url)
        XCTAssertNil(session.issue)
        let stored = try await f.store.load(id: document.documentID)
        XCTAssertEqual(stored.document.revision, 0)
    }

    @MainActor
    func testMissingDocumentThrowsLoadErrorWithoutAFalseEditor() async throws {
        let f = try Fixture(); defer { f.remove() }
        let missing = UUID()
        do {
            _ = try await EditorSession.open(documentID: missing, store: f.store, exports: f.exports, settings: f.settings)
            XCTFail("Missing document opened")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
        let status = await f.exports.status(documentID: missing)
        XCTAssertEqual(status, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.defaultFolder.path))
    }

    @MainActor
    func testQualityCommitRejectsInvalidInputAndWaitsBehindSavedEdits() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        f.settings.setFormat(.jpeg)
        let document = try await f.create()
        let gate = Gate<Void>(); defer { gate.fail() }
        var requests: [Data] = []
        let session = try await f.open(document, beforeSave: { try await gate.run() }, beforeExportSubmit: { request in
            XCTAssertEqual(request.revision, 1)
            requests.append(try await request.encode())
        })
        let before = f.settings.snapshot
        for invalid in [-1.0, 2.0, Double.nan] {
            XCTAssertThrowsError(try session.commitJPEGQuality(invalid)) { XCTAssertEqual($0 as? ExportSettingsError, .invalidQuality) }
            XCTAssertEqual(f.settings.snapshot, before)
        }
        try await idle(session)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(session.persisted.revision, 0)
        session.commitDraft()
        session.requestExport()
        try await gate.waitStarted()
        try session.commitJPEGQuality(0.2)
        session.requestExport()
        XCTAssertEqual(f.settings.snapshot.jpegQuality, 0.2)
        XCTAssertTrue(requests.isEmpty)
        gate.finish(.success(()))
        try await idle(session)
        _ = try await settle(f, document.documentID)
        let image = try RasterImageDecoder.decode(f.original)
        let high = try RasterImageCodec.encode(image, format: .jpeg(quality: 0.9))
        let low = try RasterImageCodec.encode(image, format: .jpeg(quality: 0.2))
        XCTAssertNotEqual(high, low, "Fixture must distinguish the two requested JPEG qualities")
        XCTAssertEqual(requests, [high, low])
        XCTAssertEqual(session.persisted.revision, 1)
    }

    @MainActor
    func testStatusSubscriberReleasesSessionAfterActualStatusAcknowledgment() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.settings.setDestinationFolder(f.a)
        let document = try await f.create()
        var session: EditorSession? = try await f.open(document)
        session!.requestExport()
        try await idle(session!)
        let saved = try await settle(f, document.documentID)
        try await observed(session!) { $0 == saved }
        let observer = { [weak session] in session }
        session = nil
        XCTAssertNil(observer(), "Status consumer must not retain self across AsyncStream.next")
        let receipt = try await f.exports.existing(documentID: document.documentID, slot: .png)
        XCTAssertNotNil(receipt)
    }

    @MainActor
    func testCancelledIdleObserverStillChecksActualSavedStateAtReturn() async throws {
        for fails in [false, true] {
            let f = try Fixture(); defer { f.remove() }
            try f.settings.setDestinationFolder(f.a)
            let document = try await f.create()
            let gate = Gate<Void>(); defer { gate.fail() }
            var checkpointUnwound = false
            let session = try await f.open(document, beforeSave: {
                defer { checkpointUnwound = true }
                try await gate.run()
                if fails { throw Injected.save }
            })
            session.commitDraft()
            try await gate.waitStarted()
            let entered = XCTestExpectation(description: "Two idle observers registered")
            entered.expectedFulfillmentCount = 2
            let observe: @MainActor () async throws -> Void = {
                entered.fulfill()
                await session.waitUntilIdle()
                XCTAssertTrue(checkpointUnwound)
                XCTAssertFalse(session.isProcessing, "Check processing at idle return, before another await")
                XCTAssertEqual(session.persisted.revision, fails ? 0 : 1)
                XCTAssertEqual(session.hasUnpersistedChanges, fails)
                let stored = try await f.store.load(id: document.documentID)
                XCTAssertEqual(stored.document.revision, fails ? 0 : 1)
            }
            let a = Task { try await observe() }; let b = Task { try await observe() }
            try await acknowledge(entered)
            a.cancel()
            gate.finish(.success(()))
            _ = try await completed(a).get(); _ = try await completed(b).get()
            if fails {
                if case .persistence(let error)? = session.issue { XCTAssertEqual(error as? Injected, .save) }
                else { XCTFail("Failed worker not reported") }
            } else { _ = try await settle(f, document.documentID) }
        }
    }

    private enum Injected: Error, Equatable { case save, fixture, timeout }
    private static func decodedPixels(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2); XCTAssertEqual(image.height, 2)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func mask() -> EditState {
        EditState(objects: [EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 1, height: 1), style: .grayMask(brightness: 0.5))])
    }
    @MainActor private func assertConflict(_ session: EditorSession) {
        if case .persistence(let error)? = session.issue {
            XCTAssertEqual(error as? DocumentStoreError, .revisionConflict(expected: 0, actual: 1))
        } else { XCTFail("Expected actual revision conflict") }
    }
    @MainActor private func assertMaskFailure(_ session: EditorSession) {
        if case .rendering(let error)? = session.issue {
            XCTAssertEqual(error as? DocumentStoreError, .invalidEdits)
        } else { XCTFail("Expected renderer rejection") }
    }
    @MainActor private func acknowledge(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw Injected.timeout }
    }
    @MainActor private func completed<Value>(_ task: Task<Value, Error>) async throws -> Result<Value, Error> {
        let done = XCTestExpectation(description: "Editor operation completed")
        let observer = Task { let result = await task.result; done.fulfill(); return result }
        do { try await acknowledge(done) }
        catch { task.cancel(); observer.cancel(); throw error }
        return await observer.value
    }
    @MainActor private func idle(_ session: EditorSession) async throws {
        let task: Task<Void, Error> = Task { await session.waitUntilIdle() }
        _ = try await completed(task).get()
        XCTAssertFalse(session.isProcessing)
    }
    @MainActor private func settle(_ fixture: Fixture, _ id: UUID) async throws -> ExportStatus {
        try await completed(Task { try await fixture.exports.waitUntilSettled(documentID: id) }).get()
    }
    @MainActor private func existing(_ fixture: Fixture, _ id: UUID, _ slot: ExportSlot) async throws -> PublishedExport? {
        try await fixture.exports.existing(documentID: id, slot: slot)
    }
    @MainActor private func observed(_ session: EditorSession, matches: @escaping @MainActor (ExportStatus) -> Bool) async throws {
        let watch = StatusWatch(session: session, matches: matches)
        defer { watch.stop() }
        watch.arm()
        try await acknowledge(watch.reached)
    }

    @MainActor private final class StatusWatch {
        let observeSession: () -> EditorSession?
        let matches: @MainActor (ExportStatus) -> Bool
        let reached = XCTestExpectation(description: "Session observed actual export status")
        private var stopped = false
        init(session: EditorSession, matches: @escaping @MainActor (ExportStatus) -> Bool) {
            observeSession = { [weak session] in session }; self.matches = matches
        }
        func arm() {
            guard !stopped, let session = observeSession() else { return }
            if matches(session.exportStatus) { stopped = true; reached.fulfill(); return }
            withObservationTracking { _ = session.exportStatus } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.arm() }
            }
        }
        func stop() { stopped = true }
    }
    @MainActor private final class Gate<Value> {
        let entered = XCTestExpectation(description: "Before-save checkpoint entered")
        private var started = false
        private var pending: CheckedContinuation<Value, Error>?
        private var early: Result<Value, Error>?
        func run() async throws -> Value {
            precondition(!started); started = true; entered.fulfill()
            if let early { return try early.get() }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func waitStarted() async throws {
            if started { return }
            let result = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            XCTAssertEqual(result, .completed)
            guard result == .completed else { fail(); throw Injected.timeout }
        }
        func finish(_ result: Result<Value, Error>) { early = result; let continuation = pending; pending = nil; continuation?.resume(with: result) }
        func fail() { finish(.failure(Injected.save)) }
    }
    @MainActor private final class Fixture {
        let suite = "getGamen.EditorSessionTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        let a: URL
        let b: URL
        let defaultFolder: URL
        let store: DocumentStore
        let exports: AutomaticExportCoordinator
        let settings: ExportSettings
        let original: Data
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-editor-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            a = root.appendingPathComponent("A", isDirectory: true)
            b = root.appendingPathComponent("B", isDirectory: true)
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
            defaultFolder = root.appendingPathComponent("getGamen", isDirectory: true)
            store = try DocumentStore(root: root.appendingPathComponent("documents", isDirectory: true))
            exports = try AutomaticExportCoordinator(receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true))
            settings = ExportSettings(defaults: defaults, defaultFolder: defaultFolder)
            let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255]
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            original = try RasterImageCodec.encode(image, format: .png)
        }
        func create() async throws -> EditDocument { try await store.create(original: original, pixelSize: PixelSize(width: 2, height: 2)) }
        func open(_ document: EditDocument, initialSettings: ExportSettingsSnapshot? = nil,
                  beforeSave: @escaping @MainActor () async throws -> Void = {},
                  beforeExportSubmit: @escaping @MainActor (ExportRequest) async throws -> Void = { _ in }) async throws -> EditorSession {
            try await EditorSession.open(documentID: document.documentID, store: store, exports: exports,
                settings: settings, initialSettings: initialSettings, beforeSave: beforeSave, beforeExportSubmit: beforeExportSubmit)
        }
        func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
}
