import Foundation
import XCTest
import GetGamenCore

final class DocumentStoreTests: XCTestCase {
    private let pixels = PixelSize(width: 100, height: 80)
    private let source = Data([0, 1, 2, 127, 255])

    func testReopenPreservesOriginalEditsDateAndIndependentDocuments() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root)
        let first = try await store.create(original: source, pixelSize: pixels)
        let second = try await store.create(original: source, pixelSize: pixels)
        XCTAssertNotEqual(first.documentID, second.documentID)
        XCTAssertEqual(first.documentID, first.originalID)
        XCTAssertEqual(first.schemaVersion, 1)
        XCTAssertEqual(first.revision, 0)
        XCTAssertEqual(first.originalByteCount, source.count)
        // A separately calculated SHA256 fixture, not the store's own hashing code.
        XCTAssertEqual(first.originalSHA256, "5f20fb8fce780f8212528dd8bf5287001a1919ec8d110cf6cebbfe20a660850a")
        var edits = sampleEdits()
        let saved = try await store.save(id: first.documentID, edits: edits, expectedRevision: 0)
        edits.crop = PixelCrop(x: 70, y: 60, width: 10, height: 10)
        let savedAgain = try await store.save(id: first.documentID, edits: edits, expectedRevision: 1)
        let reopened = try DocumentStore(root: root)
        let loaded = try await reopened.load(id: first.documentID)
        XCTAssertEqual(loaded.originalData, source)
        XCTAssertEqual(loaded.document, savedAgain)
        XCTAssertEqual(loaded.document.edits, edits)
        XCTAssertEqual(loaded.document.createdAt, first.createdAt)
        XCTAssertEqual(saved.createdAt, first.createdAt)
        XCTAssertEqual(savedAgain.revision, 2)
        XCTAssertEqual(try Data(contentsOf: originalURL(root, first.documentID)), source)
        let other = try await reopened.load(id: second.documentID)
        XCTAssertEqual(other.document.revision, 0)
        XCTAssertTrue(other.document.edits.objects.isEmpty)
    }

    func testFractionalDateSurvivesLoadAndSaveExactly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root)
        let document = try await store.create(original: source, pixelSize: pixels)
        let timestamp = 12345.125
        try changeJSON(root, document.documentID) { $0["createdAt"] = timestamp }
        let loaded = try await store.load(id: document.documentID)
        XCTAssertEqual(loaded.document.createdAt.timeIntervalSinceReferenceDate, timestamp)
        let saved = try await store.save(id: document.documentID, edits: sampleEdits(), expectedRevision: 0)
        XCTAssertEqual(saved.createdAt.timeIntervalSinceReferenceDate, timestamp)
    }

    func testRejectedEditsAndStaleRevisionPreserveGoodFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root)
        let document = try await store.create(original: source, pixelSize: pixels)
        _ = try await store.save(id: document.documentID, edits: sampleEdits(), expectedRevision: 0)
        let goodJSON = try Data(contentsOf: jsonURL(root, document.documentID))
        do {
            _ = try await store.save(id: document.documentID, edits: EditState(objects: [], crop: nil), expectedRevision: 0)
            XCTFail("A stale save must fail")
        } catch { XCTAssertEqual(error as? DocumentStoreError, .revisionConflict(expected: 0, actual: 1)) }
        let invalid = EditState(objects: [EditObject(id: UUID(), bounds: PixelBounds(x: .nan, y: 0, width: 1, height: 1), style: .grayMask(brightness: 0.5))], crop: nil)
        do {
            _ = try await store.save(id: document.documentID, edits: invalid, expectedRevision: 1)
            XCTFail("Invalid edits must fail")
        } catch { XCTAssertEqual(error as? DocumentStoreError, .invalidEdits) }
        XCTAssertEqual(try Data(contentsOf: jsonURL(root, document.documentID)), goodJSON)
        XCTAssertEqual(try Data(contentsOf: originalURL(root, document.documentID)), source)
    }

    func testConcurrentSameRevisionAllowsExactlyOneCommit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root)
        let document = try await store.create(original: source, pixelSize: pixels)
        let id = document.documentID
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for brightness in [0.2, 0.8] {
                group.addTask {
                    let object = EditObject(id: UUID(), bounds: PixelBounds(x: 0, y: 0, width: 5, height: 5), style: .grayMask(brightness: brightness))
                    do {
                        _ = try await store.save(id: id, edits: EditState(objects: [object], crop: nil), expectedRevision: 0)
                        return true
                    } catch { return false }
                }
            }
            var result: [Bool] = []
            for await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        let loaded = try await store.load(id: id)
        XCTAssertEqual(loaded.document.revision, 1)
        XCTAssertEqual(loaded.document.edits.objects.count, 1)
        XCTAssertEqual(loaded.originalData, source)
    }

    func testUnknownVersionsCorruptionAndForeignIdentityAreRejectedWithoutReplacement() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 99 },
            { $0["documentID"] = UUID().uuidString },
            { $0["originalID"] = UUID().uuidString },
            { $0["edits"] = ["objects": [["id": UUID().uuidString, "bounds": ["x": 0, "y": 0, "width": 1, "height": 1], "style": ["futureTool": [:]]]]] }
        ]
        for mutate in mutations {
            let document = try await store.create(original: source, pixelSize: pixels)
            try changeJSON(root, document.documentID, mutate)
            let before = try Data(contentsOf: jsonURL(root, document.documentID))
            await assertLoadFails(store, id: document.documentID)
            XCTAssertEqual(try Data(contentsOf: jsonURL(root, document.documentID)), before)
            XCTAssertEqual(try Data(contentsOf: originalURL(root, document.documentID)), source)
        }
        let document = try await store.create(original: source, pixelSize: pixels)
        let bad = Data("{broken".utf8)
        try bad.write(to: jsonURL(root, document.documentID))
        await assertLoadFails(store, id: document.documentID)
        XCTAssertEqual(try Data(contentsOf: jsonURL(root, document.documentID)), bad)
    }

    func testMissingOrAlteredOriginalFailsWithoutRecreatingIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root)
        let document = try await store.create(original: source, pixelSize: pixels)
        let original = originalURL(root, document.documentID)
        let altered = Data([0, 1, 2, 127, 254]) // Same length, different hash.
        try altered.write(to: original)
        await assertLoadFails(store, id: document.documentID)
        XCTAssertEqual(try Data(contentsOf: original), altered)
        try FileManager.default.removeItem(at: original)
        await assertLoadFails(store, id: document.documentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testSymlinkOriginalJSONAndRootNeverModifyTheirTargets() async throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("owned", isDirectory: true)
        let target = parent.appendingPathComponent("external-input.png")
        let export = parent.appendingPathComponent("external-output.jpg")
        try source.write(to: target)
        try source.write(to: export)
        let store = try DocumentStore(root: root)
        for filename in ["original.bin", "document.json"] {
            let document = try await store.create(original: source, pixelSize: pixels)
            let url = root.appendingPathComponent(document.documentID.uuidString).appendingPathComponent(filename)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            await assertLoadFails(store, id: document.documentID)
            do {
                _ = try await store.save(id: document.documentID, edits: sampleEdits(), expectedRevision: 0)
                XCTFail("A symlink must reject a save")
            } catch { }
        }
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try DocumentStore(root: alias))
        let dangling = parent.appendingPathComponent("dangling")
        let nonexistent = parent.appendingPathComponent("not-created")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: nonexistent)
        XCTAssertThrowsError(try DocumentStore(root: dangling))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonexistent.path))
        XCTAssertEqual(try Data(contentsOf: target), source)
        XCTAssertEqual(try Data(contentsOf: export), source)
    }

    func testRejectsEmptySourceAndOverflowDimensionsBeforePublishing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root)
        do {
            _ = try await store.create(original: Data(), pixelSize: pixels)
            XCTFail("Empty source must fail")
        } catch { XCTAssertEqual(error as? DocumentStoreError, .emptyOriginal) }
        do {
            _ = try await store.create(original: source, pixelSize: PixelSize(width: Int.max, height: 2))
            XCTFail("Dimension overflow must fail")
        } catch { XCTAssertEqual(error as? DocumentStoreError, .invalidPixelSize) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRevisionOverflowAndUnknownVersionHaveSpecificErrors() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root)
        let document = try await store.create(original: source, pixelSize: pixels)
        try changeJSON(root, document.documentID) { $0["revision"] = NSNumber(value: UInt64.max) }
        let before = try Data(contentsOf: jsonURL(root, document.documentID))
        do {
            _ = try await store.save(id: document.documentID, edits: sampleEdits(), expectedRevision: .max)
            XCTFail("Revision overflow must fail")
        } catch { XCTAssertEqual(error as? DocumentStoreError, .revisionOverflow) }
        XCTAssertEqual(try Data(contentsOf: jsonURL(root, document.documentID)), before)
        try changeJSON(root, document.documentID) { $0["schemaVersion"] = 99 }
        do {
            _ = try await store.load(id: document.documentID)
            XCTFail("Unknown schema must not be decoded as current")
        } catch { XCTAssertEqual(error as? DocumentStoreError, .unsupportedSchemaVersion(99)) }
    }

    func testDocumentDirectoryAndDanglingOriginalLinksAreRejected() async throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("owned")
        let store = try DocumentStore(root: root)
        let document = try await store.create(original: source, pixelSize: pixels)
        let directory = root.appendingPathComponent(document.documentID.uuidString)
        let external = parent.appendingPathComponent("moved-document")
        try FileManager.default.moveItem(at: directory, to: external)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: external)
        await assertLoadFails(store, id: document.documentID)
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("original.bin")), source)
        let second = try await store.create(original: source, pixelSize: pixels)
        let original = originalURL(root, second.documentID)
        try FileManager.default.removeItem(at: original)
        let missing = parent.appendingPathComponent("missing-original")
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: missing)
        await assertLoadFails(store, id: second.documentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testReopenRemovesOnlyAbandonedStagingDirectories() async throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("owned", isDirectory: true)
        let store = try DocumentStore(root: root)
        let document = try await store.create(original: source, pixelSize: pixels)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try source.write(to: staging.appendingPathComponent("original.bin"))
        let external = parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let externalFile = external.appendingPathComponent("original.bin")
        try source.write(to: externalFile)
        let link = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let unrelatedDirectory = root.appendingPathComponent(".staging-notauuid", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: false)
        let unrelatedFile = root.appendingPathComponent("notes.txt")
        try source.write(to: unrelatedFile)

        let reopened = try DocumentStore(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), external.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: externalFile), source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: unrelatedFile), source)
        let loaded = try await reopened.load(id: document.documentID)
        XCTAssertEqual(loaded.document, document)
        XCTAssertEqual(loaded.originalData, source)
    }

    func testRemovingPreviousDocumentsKeepsLinksAndUnrelatedFiles() async throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("owned", isDirectory: true)
        _ = try await DocumentStore(root: root).create(original: source, pixelSize: pixels)
        let external = parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let externalFile = external.appendingPathComponent("original.bin")
        try source.write(to: externalFile)
        let linkID = UUID()
        let link = root.appendingPathComponent(linkID.uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let unrelatedFile = root.appendingPathComponent("notes.txt")
        try source.write(to: unrelatedFile)

        let fresh = try DocumentStore(root: root, removesPreviousDocuments: true)
        let remaining = try await fresh.documentIDs()
        XCTAssertEqual(remaining, [linkID], "Only real document directories are removed")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), external.path)
        XCTAssertEqual(try Data(contentsOf: externalFile), source)
        XCTAssertEqual(try Data(contentsOf: unrelatedFile), source)
    }

    private func sampleEdits() -> EditState {
        EditState(objects: [EditObject(id: UUID(), bounds: PixelBounds(x: 2, y: 3, width: 20, height: 30),
                                      style: .grayMask(brightness: 0.5))], crop: nil)
    }
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-store-tests-\(UUID().uuidString)", isDirectory: true)
    }
    private func jsonURL(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("document.json")
    }
    private func originalURL(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("original.bin")
    }
    private func changeJSON(_ root: URL, _ id: UUID, _ mutate: (inout [String: Any]) -> Void) throws {
        let url = jsonURL(root, id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        mutate(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
    private func assertLoadFails(_ store: DocumentStore, id: UUID, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await store.load(id: id)
            XCTFail("Invalid persisted data must fail without replacement", file: file, line: line)
        } catch { }
    }
}
