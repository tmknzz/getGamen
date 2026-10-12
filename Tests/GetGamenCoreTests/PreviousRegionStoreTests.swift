import Foundation
import Darwin
import XCTest
@testable import GetGamenCore

final class PreviousRegionStoreTests: XCTestCase {
    func testMissingRecordCreatesParentAndRoundTripsActualVersionOneFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/owned/previous-region.json")
        let store = try PreviousRegionRecordStore(fileURL: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertNil(try store.load())
        let expected = selection()
        try store.remember(expected)
        XCTAssertEqual(try PreviousRegionRecordStore(fileURL: file).load(), expected)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "selection"])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let storedSelection = try XCTUnwrap(json["selection"] as? [String: Any])
        XCTAssertNil(storedSelection["runtimeID"])
        XCTAssertNil(storedSelection["pixelSize"])
        XCTAssertNil(storedSelection["tiles"])
    }

    func testInitializationPreservesCorruptBytesAndSuccessfulRememberCanReplaceThem() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("previous-region.json")
        let bad = Data("not json".utf8)
        try bad.write(to: file)
        let store = try PreviousRegionRecordStore(fileURL: file)
        XCTAssertEqual(try Data(contentsOf: file), bad)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? PreviousRegionError, .corruptRecord) }
        XCTAssertEqual(try Data(contentsOf: file), bad)
        try store.remember(selection())
        XCTAssertEqual(try store.load(), selection())
    }

    func testOuterVersionIsReadBeforeMissingOrIncompatibleSelection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("previous-region.json")
        let store = try PreviousRegionRecordStore(fileURL: file)
        for text in ["{\"schemaVersion\":9}", "{\"schemaVersion\":9,\"selection\":false}"] {
            let data = Data(text.utf8)
            try data.write(to: file)
            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? PreviousRegionError, .unsupportedRecordVersion(9))
            }
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
        for text in ["{}", "{\"schemaVersion\":true}", "{\"schemaVersion\":\"1\"}",
                     "{\"schemaVersion\":1.5}", "{\"schemaVersion\":1}",
                     "{\"schemaVersion\":1,\"selection\":false}"] {
            let data = Data(text.utf8)
            try data.write(to: file)
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? PreviousRegionError, .corruptRecord) }
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testInnerVersionAndSemanticValidationAreLeftForGeometry() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreviousRegionRecordStore(fileURL: root.appendingPathComponent("previous-region.json"))
        let future = selection(version: 91)
        try store.remember(future)
        XCTAssertEqual(try store.load(), future)
        let invalidGeometry = RegionSelection(schemaVersion: 1, anchorID: "",
            dragInAnchor: RegionRect(x: 0, y: 0, width: -1, height: 1), displays: [])
        try store.remember(invalidGeometry)
        XCTAssertEqual(try store.load(), invalidGeometry, "Store must not duplicate topology validation")
    }

    func testCheckpointFailurePreservesOldBytesAndSuccessfulCheckpointStillWrites() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("previous-region.json")
        let original = selection()
        try PreviousRegionRecordStore(fileURL: file).remember(original)
        let before = try Data(contentsOf: file)
        let injected = NSError(domain: "PreviousRegionStoreTests.Checkpoint", code: 7)
        var checkpointCalls = 0
        let failing = try PreviousRegionRecordStore(fileURL: file, beforeAtomicWrite: {
            checkpointCalls += 1
            throw injected
        })
        XCTAssertThrowsError(try failing.remember(selection(x: 20))) {
            XCTAssertEqual(($0 as NSError).domain, injected.domain)
            XCTAssertEqual(($0 as NSError).code, injected.code)
        }
        XCTAssertEqual(checkpointCalls, 1)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try failing.load(), original)
        let succeeding = try PreviousRegionRecordStore(fileURL: file, beforeAtomicWrite: { checkpointCalls += 1 })
        try succeeding.remember(selection(x: 20))
        XCTAssertEqual(checkpointCalls, 2)
        XCTAssertEqual(try PreviousRegionRecordStore(fileURL: file).load(), selection(x: 20))
        XCTAssertNotEqual(try Data(contentsOf: file), before)
    }

    func testEncodingAndPathFailuresPrecedeCheckpointAndPreserveRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned/previous-region.json")
        var calls = 0
        let store = try PreviousRegionRecordStore(fileURL: file, beforeAtomicWrite: { calls += 1 })
        try store.remember(selection())
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.remember(selection(x: .nan)))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: file.deletingLastPathComponent(), to: moved)
        assertPOSIX(ENOENT) { _ = try store.load() }
        assertPOSIX(ENOENT) { try store.remember(selection(x: 20)) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(file.lastPathComponent)), before)
    }

    func testRecordAndParentSymlinksAreRejectedIncludingDanglingLinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let targetData = Data("unchanged".utf8)
        try targetData.write(to: target)
        for (name, destination) in [("link.json", target), ("dangling.json", root.appendingPathComponent("missing"))] {
            let link = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            assertPOSIX(ELOOP) { _ = try PreviousRegionRecordStore(fileURL: link) }
        }
        let realParent = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        let parentLink = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: realParent)
        assertPOSIX(ELOOP) { _ = try PreviousRegionRecordStore(fileURL: parentLink.appendingPathComponent("record.json")) }
        let danglingParent = root.appendingPathComponent("dangling-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: danglingParent, withDestinationURL: root.appendingPathComponent("absent"))
        assertPOSIX(ELOOP) { _ = try PreviousRegionRecordStore(fileURL: danglingParent.appendingPathComponent("record.json")) }
        XCTAssertEqual(try Data(contentsOf: target), targetData)
    }

    func testPathsAreRevalidatedForLoadAndRememberAndNonregularFilesFail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned/record.json")
        let store = try PreviousRegionRecordStore(fileURL: file)
        let target = root.appendingPathComponent("target.json")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        assertPOSIX(ELOOP) { _ = try store.load() }
        assertPOSIX(ELOOP) { try store.remember(selection()) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        assertPOSIX(EFTYPE) { _ = try store.load() }
        assertPOSIX(EFTYPE) { try store.remember(selection()) }
        assertPOSIX(EFTYPE) { _ = try PreviousRegionRecordStore(fileURL: file) }
        let parent = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: parent)
        try Data("not a directory".utf8).write(to: parent)
        assertPOSIX(ENOTDIR) { _ = try store.load() }
        assertPOSIX(ENOTDIR) { try store.remember(selection()) }
        assertPOSIX(ENOTDIR) { _ = try PreviousRegionRecordStore(fileURL: file) }
        assertPOSIX(EINVAL) { _ = try PreviousRegionRecordStore(fileURL: URL(string: "https://example.com/record.json")!) }
        XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
    }

    func testReplacingOwnedParentWithLinkFailsWithoutChangingRetainedBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned/record.json")
        let store = try PreviousRegionRecordStore(fileURL: file)
        try store.remember(selection())
        let before = try Data(contentsOf: file)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        let parent = file.deletingLastPathComponent()
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        assertPOSIX(ELOOP) { _ = try store.load() }
        assertPOSIX(ELOOP) { try store.remember(selection(x: 20)) }
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("record.json")), before)
    }

    func testEmbeddedNullAndRootRecordLocationsAreRejectedBeforeFileOperations() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("record.json")
        let bytes = Data("retain".utf8)
        try bytes.write(to: target)
        let nullFile = URL(fileURLWithPath: target.path + "\0ignored")
        assertPOSIX(EINVAL) { _ = try PreviousRegionRecordStore(fileURL: nullFile) }
        let nullParent = URL(fileURLWithPath: root.path + "\0ignored/record.json")
        assertPOSIX(EINVAL) { _ = try PreviousRegionRecordStore(fileURL: nullParent) }
        assertPOSIX(EINVAL) { _ = try PreviousRegionRecordStore(fileURL: URL(fileURLWithPath: "/")) }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-PreviousStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func selection(version: Int = 1, x: Double = 10) -> RegionSelection {
        RegionSelection(schemaVersion: version, anchorID: "display-a",
            dragInAnchor: RegionRect(x: x, y: 20, width: 40, height: 30),
            displays: [RegionDisplayReference(id: "display-a", relativeX: 0, relativeY: 0,
                width: 500, height: 400, scale: 2, rotation: 0, backingWidth: 1000, backingHeight: 800)])
    }

    private func assertPOSIX(_ code: Int32, file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain, file: file, line: line)
            XCTAssertEqual(($0 as NSError).code, Int(code), file: file, line: line)
        }
    }
}
