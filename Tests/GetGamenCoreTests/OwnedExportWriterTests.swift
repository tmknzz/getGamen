import Darwin
import Foundation
import XCTest
@testable import GetGamenCore

final class OwnedExportWriterTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)
    private let old = Data("complete old image".utf8)
    private let new = Data("complete new image".utf8)

    func testReplacementBetweenValidationAndPublicationIsNeverOverwritten() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID()
        var initial = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&initial, f, id, 1, old)
        let stranger = Data("external replacement".utf8)
        var raced = false
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts) { point, _, _ in
            if case .beforeRename = point, !raced {
                raced = true
                try stranger.write(to: first.url, options: .atomic)
            }
        }
        XCTAssertThrowsError(try publish(&writer, f, id, 2, new))
        XCTAssertTrue(raced)
        XCTAssertEqual(try Data(contentsOf: first.url), stranger)
    }

    func testCreateUpdateReopenAndExtensionSlotsPreserveInputs() throws {
        let f = try Fixture()
        defer { f.remove() }
        let input = f.root.appendingPathComponent("input.png")
        try old.write(to: input)
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, old)
        XCTAssertEqual(first.url.lastPathComponent, CaptureFilename.stem(createdAt: date) + ".png")
        XCTAssertEqual(first.stamp, ExportStamp(request: 1, documentRevision: 1))
        let second = try publish(&writer, f, id, 2, new)
        XCTAssertNotEqual(second.url, first.url)
        XCTAssertEqual(try Data(contentsOf: second.url), new)
        var reopened = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertEqual(try reopened.existing(documentID: id, slot: .png), second)
        let third = try publish(&reopened, f, id, 3, old)
        XCTAssertNotEqual(third.url, first.url)
        let jpeg = try reopened.publish(documentID: id, createdAt: date, slot: .jpg, destinationFolder: f.output,
                                        data: new, stamp: ExportStamp(request: 4, documentRevision: 3))
        XCTAssertEqual(jpeg.url.pathExtension, "jpg")
        XCTAssertNotEqual(jpeg.url, first.url)
        XCTAssertEqual(try Data(contentsOf: first.url), old)
        XCTAssertEqual(try Data(contentsOf: input), old)
        XCTAssertEqual(try reopened.maximumRequestNumber(), 4)
    }

    func testCollisionAndEqualDatesNeverOverwriteAnotherImage() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        let collision = f.output.appendingPathComponent(CaptureFilename.stem(createdAt: date) + ".png")
        try old.write(to: collision)
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, new)
        let second = try publish(&writer, f, UUID(), 2, new)
        XCTAssertEqual(first.url.lastPathComponent, CaptureFilename.stem(createdAt: date) + "-2.png")
        XCTAssertEqual(second.url.lastPathComponent, CaptureFilename.stem(createdAt: date) + "-3.png")
        XCTAssertNotEqual(first.url, collision)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try Data(contentsOf: collision), old)
        XCTAssertEqual(try Data(contentsOf: first.url), new)
    }

    func testNumberedCollisionsFallBackToUUIDWithoutOverwritingExistingFiles() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        let stem = CaptureFilename.stem(createdAt: date)
        let collisions = (1...32).map { number in
            f.output.appendingPathComponent("\(stem)\(number == 1 ? "" : "-" + String(number)).png")
        }
        for url in collisions { try old.write(to: url) }
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let result = try publish(&writer, f, id, 1, new)
        XCTAssertFalse(collisions.contains(result.url))
        XCTAssertTrue(result.url.lastPathComponent.hasPrefix(stem + "-"))
        XCTAssertTrue(result.url.lastPathComponent.hasSuffix(".png"))
        let suffix = result.url.deletingPathExtension().lastPathComponent.dropFirst(stem.count + 1)
        XCTAssertNotNil(UUID(uuidString: String(suffix)))
        XCTAssertEqual(try Data(contentsOf: result.url), new)
        for url in collisions { XCTAssertEqual(try Data(contentsOf: url), old) }
        let reopened = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertEqual(try reopened.existing(documentID: id, slot: .png)?.url, result.url)
    }

    func testReplacementWithIdenticalBytesAndInPlaceEditsLoseOwnership() throws {
        for replacement in [true, false] {
            let f = try Fixture()
            defer { f.remove() }
            let id = UUID()
            var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
            let first = try publish(&writer, f, id, 1, old)
            if replacement {
                let other = f.output.appendingPathComponent("replacement")
                try old.write(to: other)
                // A different inode with exactly the same bytes is still not ours.
                try replace(other, first.url)
            } else {
                let file = try FileHandle(forWritingTo: first.url)
                try file.truncate(atOffset: 0)
                try file.write(contentsOf: new)
                try file.close()
            }
            let external = try Data(contentsOf: first.url)
            XCTAssertThrowsError(try publish(&writer, f, id, 2, old)) {
                XCTAssertEqual($0 as? ExportWriteError, .ownershipLost)
            }
            XCTAssertEqual(try Data(contentsOf: first.url), external)
        }
    }

    func testTargetSymlinksAndReplacedDestinationAreNotFollowed() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, old)
        let external = f.root.appendingPathComponent("external.png")
        try new.write(to: external)
        try FileManager.default.removeItem(at: first.url)
        try FileManager.default.createSymbolicLink(at: first.url, withDestinationURL: external)
        XCTAssertThrowsError(try publish(&writer, f, id, 2, old))
        XCTAssertEqual(try Data(contentsOf: external), new)
        let moved = f.root.appendingPathComponent("moved-output")
        try FileManager.default.moveItem(at: f.output, to: moved)
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
        XCTAssertThrowsError(try publish(&writer, f, id, 3, old))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
    }

    func testDestinationMigrationPreservesOldOutputAndFailedMigrationKeepsReceipt() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, old)
        let missing = f.root.appendingPathComponent("absent-folder")
        XCTAssertThrowsError(try writer.publish(documentID: id, createdAt: date, slot: .png, destinationFolder: missing,
                                                data: new, stamp: ExportStamp(request: 2, documentRevision: 2)))
        XCTAssertEqual(try writer.existing(documentID: id, slot: .png), first)
        let other = f.root.appendingPathComponent("new-folder")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let migrated = try writer.publish(documentID: id, createdAt: date, slot: .png, destinationFolder: other,
                                           data: new, stamp: ExportStamp(request: 3, documentRevision: 2))
        XCTAssertEqual(migrated.url.deletingLastPathComponent().standardizedFileURL, other.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: first.url), old)
        XCTAssertEqual(try Data(contentsOf: migrated.url), new)
    }

    func testRenamePreservesStagingIdentity() throws {
        let f = try Fixture()
        defer { f.remove() }
        var stageIdentity: Identity?
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts) { point, stage, _ in
            if case .beforeRename = point { stageIdentity = try self.identity(stage) }
        }
        let first = try publish(&writer, f, UUID(), 1, new)
        XCTAssertEqual(try identity(first.url), try XCTUnwrap(stageIdentity))
    }

    func testBeforeRenameInterruptionKeepsGoodOutputAndHighWater() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, old)
        var interrupted = try OwnedExportWriter(receiptsRoot: f.receipts) { point, _, _ in
            if case .beforeRename = point { throw SimulatedCrash() }
        }
        XCTAssertThrowsError(try publish(&interrupted, f, id, 2, new)) {
            XCTAssertEqual($0 as? ExportWriteError, .interruptedPublication)
        }
        XCTAssertEqual(try Data(contentsOf: first.url), old)
        var recovered = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertEqual(try recovered.existing(documentID: id, slot: .png), first)
        XCTAssertEqual(try recovered.maximumRequestNumber(), 2)
        XCTAssertThrowsError(try publish(&recovered, f, id, 2, new))
        XCTAssertNotEqual(try publish(&recovered, f, id, 3, new).url, first.url)
    }

    func testAfterRenameRecoverySettlesNewOutputWithoutRewritingIt() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, old)
        var publishedURL: URL?
        var interrupted = try OwnedExportWriter(receiptsRoot: f.receipts) { point, _, target in
            if case .afterRename = point { publishedURL = target; throw SimulatedCrash() }
        }
        XCTAssertThrowsError(try publish(&interrupted, f, id, 2, new)) {
            XCTAssertEqual($0 as? ExportWriteError, .interruptedPublication)
        }
        let target = try XCTUnwrap(publishedURL)
        let publishedIdentity = try identity(target)
        XCTAssertEqual(try Data(contentsOf: first.url), old)
        XCTAssertEqual(try Data(contentsOf: target), new)
        let recovered = try OwnedExportWriter(receiptsRoot: f.receipts)
        let result = try XCTUnwrap(recovered.existing(documentID: id, slot: .png))
        XCTAssertEqual(result.stamp.request, 2)
        XCTAssertEqual(result.url, target)
        XCTAssertEqual(try identity(result.url), publishedIdentity)
    }

    func testMigrationAfterRenameRecoveryChecksNewTargetBeforeOldOne() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, old)
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        var interrupted = try OwnedExportWriter(receiptsRoot: f.receipts) { point, _, _ in
            if case .afterRename = point { throw SimulatedCrash() }
        }
        XCTAssertThrowsError(try interrupted.publish(documentID: id, createdAt: date, slot: .png, destinationFolder: other,
                                                     data: new, stamp: ExportStamp(request: 2, documentRevision: 2)))
        XCTAssertEqual(try Data(contentsOf: first.url), old)
        let recovered = try OwnedExportWriter(receiptsRoot: f.receipts)
        let result = try XCTUnwrap(recovered.existing(documentID: id, slot: .png))
        XCTAssertEqual(result.stamp.request, 2)
        XCTAssertEqual(result.url.deletingLastPathComponent().standardizedFileURL, other.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: result.url), new)
    }

    func testUnexpectedTargetAfterInterruptionIsPreservedAndNewNameAllocated() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var intended: URL?
        var interrupted = try OwnedExportWriter(receiptsRoot: f.receipts) { point, _, target in
            if case .afterRename = point { intended = target; throw SimulatedCrash() }
        }
        XCTAssertThrowsError(try publish(&interrupted, f, id, 1, old))
        let target = try XCTUnwrap(intended)
        let stranger = f.output.appendingPathComponent("stranger")
        try old.write(to: stranger) // Same bytes must not be enough to adopt it.
        try replace(stranger, target)
        var recovered = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertNil(try recovered.existing(documentID: id, slot: .png))
        XCTAssertEqual(try recovered.maximumRequestNumber(), 1)
        let next = try publish(&recovered, f, id, 2, new)
        XCTAssertNotEqual(next.url, target)
        XCTAssertEqual(try Data(contentsOf: target), old)
        XCTAssertEqual(try Data(contentsOf: next.url), new)
    }

    func testFirstCreationBeforeRenameRecoveryRemovesOnlyOwnedStage() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        let unrelated = f.output.appendingPathComponent("unrelated")
        try old.write(to: unrelated)
        let staged = try interruptedStage(f, id, 1, new)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        let recovered = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertNil(try recovered.existing(documentID: id, slot: .png))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), old)
        XCTAssertEqual(try recovered.maximumRequestNumber(), 1)
    }

    func testDiscardRecoversPendingStageAndKeepsOutputsAndUnreadableReceipts() throws {
        let f = try Fixture()
        defer { f.remove() }
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let settled = try publish(&writer, f, UUID(), 1, old)
        let staged = try interruptedStage(f, UUID(), 2, new)
        let corrupt = f.receipts.appendingPathComponent("\(UUID().uuidString).png.json")
        try Data("{broken".utf8).write(to: corrupt)

        try OwnedExportWriter(receiptsRoot: f.receipts).discardReceipts()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: f.receipts.path)
        XCTAssertEqual(remaining, [corrupt.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "Recovery removes the owned stage first")
        XCTAssertEqual(try Data(contentsOf: settled.url), old)

        try FileManager.default.removeItem(at: corrupt)
        _ = try publish(&writer, f, UUID(), 3, new)
        _ = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.receipts.path).count, 1)
        _ = try AutomaticExportCoordinator(receiptsRoot: f.receipts, discardsPreviousReceipts: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.receipts.path).isEmpty)
    }

    func testInvalidDataDatesAndStaleRequestsFailWithoutChangingGoodOutput() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertThrowsError(try publish(&writer, f, id, 0, old))
        XCTAssertThrowsError(try publish(&writer, f, id, 1, Data()))
        let first = try publish(&writer, f, id, 1, old)
        XCTAssertThrowsError(try publish(&writer, f, id, 1, new)) {
            XCTAssertEqual($0 as? ExportWriteError, .staleRequest)
        }
        XCTAssertThrowsError(try writer.publish(documentID: id, createdAt: Date(timeIntervalSince1970: .nan), slot: .png,
                                                destinationFolder: f.output, data: new,
                                                stamp: ExportStamp(request: 2, documentRevision: 2)))
        XCTAssertEqual(try Data(contentsOf: first.url), old)
        _ = try publish(&writer, f, id, .max, new)
        XCTAssertEqual(try writer.maximumRequestNumber(), .max)
    }

    func testCorruptReceiptIsNotReconstructedFromExistingFilename() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, old)
        let receipts = try FileManager.default.contentsOfDirectory(at: f.receipts, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(receipts.count, 1)
        let receipt = try XCTUnwrap(receipts.first)
        try Data("{broken".utf8).write(to: receipt)
        XCTAssertThrowsError(try writer.existing(documentID: id, slot: .png)) {
            XCTAssertEqual($0 as? ExportWriteError, .invalidReceipt)
        }
        XCTAssertThrowsError(try writer.maximumRequestNumber())
        XCTAssertThrowsError(try publish(&writer, f, id, 2, new))
        XCTAssertEqual(try Data(contentsOf: first.url), old)
    }

    func testRealPermissionLossPreservesLastGoodOutput() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory mode permissions") }
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let first = try publish(&writer, f, id, 1, old)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.output.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.output.path) }
        XCTAssertThrowsError(try publish(&writer, f, id, 2, new))
        XCTAssertEqual(try Data(contentsOf: first.url), old)
    }

    func testPrivateRootAndDestinationLinksAreRejectedIncludingDanglingOnes() throws {
        let f = try Fixture()
        defer { f.remove() }
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        let alias = f.root.appendingPathComponent("receipt-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.receipts)
        XCTAssertThrowsError(try OwnedExportWriter(receiptsRoot: alias))
        let missing = f.root.appendingPathComponent("not-created")
        let dangling = f.root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        XCTAssertThrowsError(try OwnedExportWriter(receiptsRoot: dangling))
        XCTAssertThrowsError(try writer.publish(documentID: UUID(), createdAt: date, slot: .png,
                                                destinationFolder: dangling, data: old,
                                                stamp: ExportStamp(request: 1, documentRevision: 0)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let outputAlias = f.root.appendingPathComponent("output-alias")
        try FileManager.default.createSymbolicLink(at: outputAlias, withDestinationURL: f.output)
        XCTAssertThrowsError(try writer.publish(documentID: UUID(), createdAt: date, slot: .png,
                                                destinationFolder: outputAlias, data: old,
                                                stamp: ExportStamp(request: 1, documentRevision: 0)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
    }

    func testUnknownReceiptSchemaForeignIDsAndPathTraversalReject() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 99 },
            { $0["documentID"] = UUID().uuidString },
            { $0["maximumRequest"] = 0 },
            { object in
                var association = object["settled"] as? [String: Any] ?? [:]
                association["basename"] = "../outside.png"
                object["settled"] = association
            }
        ]
        for mutate in mutations {
            let f = try Fixture()
            defer { f.remove() }
            let id = UUID()
            var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
            let first = try publish(&writer, f, id, 1, old)
            let path = f.receipts.appendingPathComponent("\(id.uuidString).png.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            mutate(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: path)
            XCTAssertThrowsError(try writer.existing(documentID: id, slot: .png)) {
                XCTAssertEqual($0 as? ExportWriteError, .invalidReceipt)
            }
            XCTAssertThrowsError(try publish(&writer, f, id, 2, new))
            XCTAssertEqual(try Data(contentsOf: first.url), old)
        }
    }

    func testNonJSONEntriesDoNotPreventReceiptEnumerationOrCoordinatorReopening() throws {
        let f = try Fixture()
        defer { f.remove() }
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        _ = try publish(&writer, f, UUID(), 7, old)
        _ = try publish(&writer, f, UUID(), 3, new)
        for name in [".DS_Store", "TemporaryFile", "notes.txt"] {
            try Data("not a receipt".utf8).write(to: f.receipts.appendingPathComponent(name))
        }
        let malformed = f.receipts.appendingPathComponent("\(UUID().uuidString).png.JSON")
        try Data("not a receipt".utf8).write(to: malformed)
        XCTAssertThrowsError(try writer.maximumRequestNumber()) {
            XCTAssertEqual($0 as? ExportWriteError, .invalidReceipt)
        }
        try FileManager.default.removeItem(at: malformed)
        XCTAssertEqual(try writer.maximumRequestNumber(), 7)
        let reopened = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertEqual(try reopened.maximumRequestNumber(), 7)
        XCTAssertNoThrow(try AutomaticExportCoordinator(receiptsRoot: f.receipts))
    }

    func testMalformedReceiptNamesCannotAliasAValidCanonicalReceipt() throws {
        for pattern in ["ID..png.json", ".ID.png.json", "ID.png..json"] {
            let f = try Fixture()
            defer { f.remove() }
            let id = UUID()
            var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
            let first = try publish(&writer, f, id, 1, old)
            let malformed = f.receipts.appendingPathComponent(pattern.replacingOccurrences(of: "ID", with: id.uuidString))
            try Data("corrupt receipt must be inspected, not skipped".utf8).write(to: malformed)
            XCTAssertThrowsError(try writer.maximumRequestNumber()) {
                XCTAssertEqual($0 as? ExportWriteError, .invalidReceipt)
            }
            XCTAssertEqual(try Data(contentsOf: first.url), old)
        }
    }

    func testDocumentRevisionHighWaterDistinguishesAbsentZeroAndBothSlots() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertNil(try writer.maximumDocumentRevision(documentID: id))
        _ = try writer.publish(documentID: id, createdAt: date, slot: .png, destinationFolder: f.output,
                               data: old, stamp: ExportStamp(request: 1, documentRevision: 0))
        XCTAssertEqual(try writer.maximumDocumentRevision(documentID: id), .some(0))
        _ = try writer.publish(documentID: id, createdAt: date, slot: .jpg, destinationFolder: f.output,
                               data: old, stamp: ExportStamp(request: 2, documentRevision: 12))
        _ = try writer.publish(documentID: id, createdAt: date, slot: .jpg, destinationFolder: f.output,
                               data: new, stamp: ExportStamp(request: 3, documentRevision: 2))
        let reopened = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertEqual(try reopened.maximumDocumentRevision(documentID: id), 12)
    }

    func testPendingRevisionSurvivesLostAssociationRecovery() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var target: URL?
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts) { point, _, url in
            if case .afterRename = point { target = url; throw SimulatedCrash() }
        }
        XCTAssertThrowsError(try writer.publish(documentID: id, createdAt: date, slot: .png, destinationFolder: f.output,
                                                data: old, stamp: ExportStamp(request: 1, documentRevision: 42)))
        try FileManager.default.removeItem(at: XCTUnwrap(target))
        let reopened = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertEqual(try reopened.maximumDocumentRevision(documentID: id), 42)
        XCTAssertNil(try reopened.existing(documentID: id, slot: .png))
        let again = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertEqual(try again.maximumDocumentRevision(documentID: id), 42)
    }

    func testLegacyPendingOnlyRecoveryPreservesHighWaterWithoutPriorRevisionQuery() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID()
        var target: URL?
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts) { point, _, url in
            if case .afterRename = point { target = url; throw SimulatedCrash() }
        }
        XCTAssertThrowsError(try writer.publish(documentID: id, createdAt: date, slot: .png, destinationFolder: f.output,
            data: old, stamp: ExportStamp(request: 9, documentRevision: 42)))
        let receipt = f.receipts.appendingPathComponent("\(id.uuidString).png.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        object.removeValue(forKey: "maximumDocumentRevision")
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        try FileManager.default.removeItem(at: XCTUnwrap(target))
        let reopened = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertNil(try reopened.existing(documentID: id, slot: .png))
        let again = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertEqual(try again.maximumDocumentRevision(documentID: id), 42)
        XCTAssertEqual(try again.maximumRequestNumber(), 9)
        let recovered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertNil(recovered["pending"])
    }

    func testLegacyRevisionDerivesFromStampsAndEmptyHistoryRemainsUnknown() throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        _ = try publish(&writer, f, id, 7, old)
        let path = f.receipts.appendingPathComponent("\(id.uuidString).png.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object.removeValue(forKey: "maximumDocumentRevision")
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        XCTAssertEqual(try writer.maximumDocumentRevision(documentID: id), 7)
        object.removeValue(forKey: "settled")
        object.removeValue(forKey: "pending")
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        XCTAssertNil(try writer.maximumDocumentRevision(documentID: id))
        XCTAssertEqual(try writer.maximumRequestNumber(), 7)
    }

    func testInvalidDocumentRevisionHighWaterIsRejected() throws {
        for invalid: Any in [0, -1, 1.5, "wrong"] {
            let f = try Fixture()
            defer { f.remove() }
            let id = UUID()
            var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
            _ = try publish(&writer, f, id, 7, old)
            let path = f.receipts.appendingPathComponent("\(id.uuidString).png.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            object["maximumDocumentRevision"] = invalid
            try JSONSerialization.data(withJSONObject: object).write(to: path)
            XCTAssertThrowsError(try writer.maximumDocumentRevision(documentID: id)) {
                XCTAssertEqual($0 as? ExportWriteError, .invalidReceipt)
            }
        }
    }

    private func publish(_ writer: inout OwnedExportWriter, _ fixture: Fixture, _ id: UUID,
                         _ request: UInt64, _ data: Data) throws -> PublishedExport {
        try writer.publish(documentID: id, createdAt: date, slot: .png, destinationFolder: fixture.output,
                           data: data, stamp: ExportStamp(request: request, documentRevision: request))
    }
    /// Crashes a publication before its rename and returns the stage it left behind.
    private func interruptedStage(_ fixture: Fixture, _ id: UUID, _ request: UInt64, _ data: Data) throws -> URL {
        var stage: URL?
        var interrupted = try OwnedExportWriter(receiptsRoot: fixture.receipts) { point, url, _ in
            if case .beforeRename = point { stage = url; throw SimulatedCrash() }
        }
        XCTAssertThrowsError(try publish(&interrupted, fixture, id, request, data))
        return try XCTUnwrap(stage)
    }
    private func replace(_ from: URL, _ to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private struct Identity: Equatable {
        let device: Int64, inode: UInt64, birthSeconds: Int64, birthNanoseconds: Int64
    }
    private func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                        birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
    private struct SimulatedCrash: Error { }
    private struct Fixture {
        let root: URL, receipts: URL, output: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-export-tests-\(UUID().uuidString)", isDirectory: true)
            receipts = root.appendingPathComponent("receipts", isDirectory: true)
            output = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
