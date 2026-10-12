import CoreGraphics
import Foundation
import XCTest
@testable import GetGamenCore

final class HistoryBatchScrollTests: XCTestCase {
    func testHistorySurvivesReopenAndDeletionPreservesExternalOutputAndOtherDocument() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(root: root.appendingPathComponent("history"))
        let original = try RasterImageCodec.encode(image(), format: .png)
        let first = try await store.create(original: original, pixelSize: PixelSize(width: 128, height: 256))
        let second = try await store.create(original: original, pixelSize: PixelSize(width: 128, height: 256))
        let edits = EditState(crop: PixelCrop(x: 2, y: 3, width: 50, height: 60))
        _ = try await store.save(id: first.documentID, edits: edits, expectedRevision: 0)
        let output = root.appendingPathComponent("export.png")
        try original.write(to: output)
        let reopened = try DocumentStore(root: root.appendingPathComponent("history"))
        let listed = try await reopened.documentIDs()
        XCTAssertEqual(Set(listed), [first.documentID, second.documentID])
        let loaded = try await reopened.load(id: first.documentID)
        XCTAssertEqual(loaded.document.edits, edits); XCTAssertEqual(loaded.originalData, original)
        try await reopened.delete(id: first.documentID)
        let remaining = try await reopened.documentIDs()
        XCTAssertEqual(remaining, [second.documentID])
        XCTAssertEqual(try Data(contentsOf: output), original)
        let other = try await reopened.load(id: second.documentID)
        XCTAssertEqual(other.originalData, original)
    }

    func testHistoryDeletionRefusesDirectorySymlink() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside"), history = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep"); try Data([1,2,3]).write(to: sentinel)
        let store = try DocumentStore(root: history), id = UUID()
        try FileManager.default.createSymbolicLink(at: history.appendingPathComponent(id.uuidString), withDestinationURL: outside)
        do { try await store.delete(id: id); XCTFail("Followed link") }
        catch { XCTAssertEqual(error as? DocumentStoreError, .unsafeFileType) }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([1,2,3]))
    }

    func testBatchKeepsSameNamedInputsUsesUniqueJobFoldersAndReportsBadInput() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
        let original = try RasterImageCodec.encode(image(), format: .png)
        let inputs = [a.appendingPathComponent("same.png"), b.appendingPathComponent("same.png")]
        for input in inputs { try original.write(to: input) }
        let bad = root.appendingPathComponent("broken.png"); try Data([1,2,3]).write(to: bad)
        let converter = BatchConverter()
        let first = try await converter.convert(inputs + [bad, URL(string: "https://example.invalid/source.png")!], destination: root, format: .png8, jpegQuality: 0.9)
        let second = try await converter.convert(inputs, destination: root, format: .jpeg, jpegQuality: 0.7)
        XCTAssertNotEqual(first.folder, second.folder)
        XCTAssertEqual(first.items.compactMap(\.output).count, 2)
        XCTAssertNotNil(first.items[2].error)
        XCTAssertNotNil(first.items[3].error, "Remote URLs must be rejected without a network request")
        XCTAssertNotEqual(first.items[0].output, first.items[1].output)
        for item in first.items.prefix(2) {
            let data = try Data(contentsOf: XCTUnwrap(item.output))
            XCTAssertEqual(data[25], 3, "PNG color type must be indexed")
            XCTAssertEqual(try RasterImageDecoder.decode(data).width, 128)
        }
        for input in inputs { XCTAssertEqual(try Data(contentsOf: input), original) }
        XCTAssertEqual(second.items.compactMap(\.output).count, 2)
    }

    func testScrollExactPixelsRejectsReverseKeepsAnchorAndResumesAfterRestore() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("checkpoint.json")
        let session = ScrollAccumulator(checkpointURL: url)
        let started = try await session.accept(image())
        XCTAssertEqual(started, .started)
        let unchanged = try await session.accept(image())
        XCTAssertEqual(unchanged, .unchanged)
        let appended = try await session.accept(image(yOffset: 37))
        XCTAssertEqual(appended, .appended(37))
        let before = try Data(contentsOf: url)
        guard case .rejected = try await session.accept(image()) else { return XCTFail("Backward accepted") }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let restored = ScrollAccumulator(checkpointURL: url)
        let recovery = try await restored.restore()
        let recovered = try XCTUnwrap(recovery)
        XCTAssertEqual(recovered.height, 293); XCTAssertEqual(recovered.frames, 2)
        XCTAssertEqual(try bytes(RasterImageDecoder.decode(recovered.png)), try bytes(image(height: 293)))
        let resumed = try await restored.accept(image(yOffset: 74))
        XCTAssertEqual(resumed, .appended(37))
        let snapshot = try await restored.snapshot()
        let finished = try XCTUnwrap(snapshot)
        XCTAssertEqual(finished.height, 330)
        XCTAssertEqual(try bytes(RasterImageDecoder.decode(finished.png)), try bytes(image(height: 330)))
        try await restored.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedCheckpointDoesNotAdvanceAcceptedState() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollAccumulator(checkpointURL: root.appendingPathComponent("missing/checkpoint.json"))
        do { _ = try await session.accept(image()); XCTFail("Missing parent accepted") } catch {}
        let snapshot = try await session.snapshot()
        XCTAssertNil(snapshot)
    }

    func testCorruptCheckpointRestorePreservesFileAndLiveAcceptedState() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("checkpoint.json")
        let session = ScrollAccumulator(checkpointURL: url)
        _ = try await session.accept(image())
        let beforeValue = try await session.snapshot()
        let before = try XCTUnwrap(beforeValue)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let badRaster = Data([1, 2, 3]).base64EncodedString()
        for (field, value) in [("version", 99 as Any), ("frames", 0 as Any),
                               ("frames", Int.max as Any), ("composite", badRaster as Any),
                               ("lastFrame", badRaster as Any)] {
            var damaged = valid; damaged[field] = value
            let corrupt = try JSONSerialization.data(withJSONObject: damaged)
            try corrupt.write(to: url)
            do { _ = try await session.restore(); XCTFail("Accepted corrupt \(field)") } catch {}
            XCTAssertEqual(try Data(contentsOf: url), corrupt, "Recovery must not erase evidence")
            let retainedValue = try await session.snapshot()
            let retained = try XCTUnwrap(retainedValue)
            XCTAssertEqual(retained.png, before.png)
            XCTAssertEqual(retained.frames, before.frames)
            let fresh = ScrollAccumulator(checkpointURL: url)
            do { _ = try await fresh.restore(); XCTFail("Fresh process accepted corrupt \(field)") } catch {}
            let empty = try await fresh.snapshot()
            XCTAssertNil(empty)
        }
        let resumed = try await session.accept(image(yOffset: 37))
        XCTAssertEqual(resumed, .appended(37), "Failed restore must not replace the last accepted anchor")
    }

    func testCheckpointWriteFailureAfterProgressCanRetryWithoutMissingRows() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active"), parked = root.appendingPathComponent("parked")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let url = active.appendingPathComponent("checkpoint.json")
        let session = ScrollAccumulator(checkpointURL: url)
        _ = try await session.accept(image())
        _ = try await session.accept(image(yOffset: 37))
        let beforeValue = try await session.snapshot()
        let before = try XCTUnwrap(beforeValue)
        let persisted = try Data(contentsOf: url)
        // Deterministic destination loss, independent of the test user's permission privileges.
        try FileManager.default.moveItem(at: active, to: parked)
        do { _ = try await session.accept(image(yOffset: 74)); XCTFail("Missing destination accepted") } catch {}
        let retainedValue = try await session.snapshot()
        let retained = try XCTUnwrap(retainedValue)
        XCTAssertEqual(retained.png, before.png); XCTAssertEqual(retained.frames, 2)
        XCTAssertEqual(try Data(contentsOf: parked.appendingPathComponent("checkpoint.json")), persisted)
        try FileManager.default.moveItem(at: parked, to: active)
        let resumed = try await session.accept(image(yOffset: 74))
        XCTAssertEqual(resumed, .appended(37))
        let fresh = ScrollAccumulator(checkpointURL: url)
        let recoveredValue = try await fresh.restore()
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.frames, 3); XCTAssertEqual(recovered.height, 330)
        XCTAssertEqual(try bytes(RasterImageDecoder.decode(recovered.png)), try bytes(image(height: 330)))
    }

    func testBatchContinuesAfterBrokenMiddleInputAndLeavesNoStagingFiles() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try RasterImageCodec.encode(image(), format: .png)
        let input = root.appendingPathComponent("source.png"), bad = root.appendingPathComponent("broken.png")
        try original.write(to: input); try Data([1, 2, 3]).write(to: bad)
        let result = try await BatchConverter().convert([input, bad, input], destination: root, format: .png, jpegQuality: 0.8)
        XCTAssertEqual(result.items.map(\.input), [input, bad, input])
        XCTAssertNotNil(result.items[1].error); XCTAssertNil(result.items[1].output)
        let first = try XCTUnwrap(result.items[0].output), last = try XCTUnwrap(result.items[2].output)
        XCTAssertNotEqual(first, last)
        for output in [first, last] {
            XCTAssertEqual(try bytes(RasterImageDecoder.decode(Data(contentsOf: output))), try bytes(image()))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: result.folder.path)
        XCTAssertEqual(Set(names), Set([first.lastPathComponent, last.lastPathComponent]))
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try Data(contentsOf: bad), Data([1, 2, 3]))
    }

    func testAlreadyCancelledBatchPublishesNothingAndKeepsInputs() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("source.png")
        let original = try RasterImageCodec.encode(image(), format: .png)
        try original.write(to: input)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BatchConverter().convert([input, input], destination: root, format: .png, jpegQuality: 0.8)
        }
        let result = try await operation.value
        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.allSatisfy { $0.output == nil && $0.error != nil })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: result.folder.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-test-\(UUID())") }
    private func image(yOffset: Int = 0, height: Int = 256) throws -> CGImage {
        var data = [UInt8](repeating: 255, count: 128 * height * 4)
        for y in 0..<height { for x in 0..<128 {
            // Structured 8-pixel features give Vision a stable registration target.
            var hash = UInt32(x / 8 + 1) &* 0x9e3779b9
            hash ^= UInt32((y + yOffset) / 8 + 1) &* 0x85ebca6b
            hash ^= hash >> 16; hash = hash &* 0xc2b2ae35; hash ^= hash >> 13
            let i = (y * 128 + x) * 4
            data[i] = UInt8(truncatingIfNeeded: hash); data[i+1] = UInt8(truncatingIfNeeded: hash >> 8); data[i+2] = UInt8(truncatingIfNeeded: hash >> 16)
        } }
        return try XCTUnwrap(CGImage(width: 128, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 512, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func bytes(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }
}
