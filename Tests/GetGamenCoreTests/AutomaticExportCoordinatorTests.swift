import Foundation
import XCTest
@testable import GetGamenCore

final class AutomaticExportCoordinatorTests: XCTestCase {
    func testTerminationBarrierIncludesSupersededWorkerAndIgnoresWaiterCancellation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let gate = Gate(); defer { Task { await gate.failAll() } }
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        let id = UUID(), otherID = UUID()
        _ = try await coordinator.submit(request(f, id: id, revision: 1) { try await gate.run(1) })
        await gate.waitUntilStarted(1)
        _ = try await coordinator.submit(request(f, id: id, revision: 2) { Data("current".utf8) })
        _ = try await coordinator.waitUntilSettled(documentID: id)
        _ = try await coordinator.submit(request(f, id: otherID, revision: 0) { throw TestError.failed })
        let failed = try await coordinator.waitUntilSettled(documentID: otherID)
        let completed = expectation(description: "All workers actually returned")
        let registered = expectation(description: "barrier registered on stale encoder")
        let observer = Task {
            let statuses = await coordinator.waitForCurrentWorkers(onWaiting: { _ in registered.fulfill() })
            completed.fulfill()
            return statuses
        }
        await fulfillment(of: [registered], timeout: 2)
        observer.cancel()
        // A cancelled observer still waits on the live stale worker.
        let early = await XCTWaiter.fulfillment(of: [completed], timeout: 0.05)
        XCTAssertEqual(early, .timedOut)
        await gate.complete(1, .success(Data("stale".utf8)))
        let statuses = await observer.value
        XCTAssertEqual(statuses[otherID], failed)
        guard case .saved(_, 2, let url) = statuses[id] else { return XCTFail("Newest result must survive") }
        XCTAssertEqual(try Data(contentsOf: url), Data("current".utf8))
    }

    func testLateSuccessAndLateFailureCannotReplaceNewestOutputOrStatus() async throws {
        for staleFails in [false, true] {
            let f = try Fixture()
            defer { f.remove() }
            let gate = Gate()
            defer { Task { await gate.failAll() } }
            let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
            let id = UUID()
            let first = try await coordinator.submit(request(f, id: id, revision: 1) { try await gate.run(1) })
            await gate.waitUntilStarted(1)
            let second = try await coordinator.submit(request(f, id: id, revision: 2) { try await gate.run(2) })
            await gate.waitUntilStarted(2)
            await gate.complete(2, .success(Data("latest".utf8)))
            let saved = try await coordinator.waitUntilSettled(documentID: id)
            let url = try savedURL(saved, request: second, revision: 2)
            if staleFails { await gate.complete(1, .failure(TestError.failed)) }
            else { await gate.complete(1, .success(Data("obsolete".utf8))) }
            await coordinator.waitForEncodingCompletion(request: first)
            let final = await coordinator.status(documentID: id)
            XCTAssertEqual(final, saved)
            XCTAssertEqual(try Data(contentsOf: url), Data("latest".utf8))
        }
    }

    func testEqualRevisionFormatChangeSuppressesObsoletePendingExtension() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let gate = Gate()
        defer { Task { await gate.failAll() } }
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        let id = UUID()
        let png = try await coordinator.submit(request(f, id: id, revision: 4, slot: .png) { try await gate.run(1) })
        await gate.waitUntilStarted(1)
        let jpeg = try await coordinator.submit(request(f, id: id, revision: 4, slot: .jpg) { try await gate.run(2) })
        await gate.waitUntilStarted(2)
        await gate.complete(2, .success(Data("jpeg".utf8)))
        let saved = try await coordinator.waitUntilSettled(documentID: id)
        XCTAssertEqual(try savedURL(saved, request: jpeg, revision: 4).pathExtension, "jpg")
        await gate.complete(1, .success(Data("png".utf8)))
        await coordinator.waitForEncodingCompletion(request: png)
        let obsolete = try await coordinator.existing(documentID: id, slot: .png)
        XCTAssertNil(obsolete)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.output.path).count, 1)
    }

    func testNewestFailurePreservesGoodFileAndSameRevisionRetrySucceeds() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        let id = UUID()
        let first = try await coordinator.submit(request(f, id: id, revision: 1) { Data("good".utf8) })
        let firstStatus = try await coordinator.waitUntilSettled(documentID: id)
        let url = try savedURL(firstStatus, request: first, revision: 1)
        let failed = try await coordinator.submit(request(f, id: id, revision: 2) { throw TestError.failed })
        let failure = try await coordinator.waitUntilSettled(documentID: id)
        guard case .failed(let number, let revision, let message) = failure else { return XCTFail("Expected failed status") }
        XCTAssertEqual(number, failed)
        XCTAssertEqual(revision, 2)
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("good".utf8))
        let retried = try await coordinator.submit(request(f, id: id, revision: 2) { Data("retried".utf8) })
        let final = try await coordinator.waitUntilSettled(documentID: id)
        XCTAssertGreaterThan(retried, failed)
        let retryURL = try savedURL(final, request: retried, revision: 2)
        XCTAssertNotEqual(retryURL, url)
        XCTAssertEqual(try Data(contentsOf: url), Data("good".utf8))
        XCTAssertEqual(try Data(contentsOf: retryURL), Data("retried".utf8))
    }

    func testIndependentDocumentsCanCompleteInEitherOrder() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let gate = Gate()
        defer { Task { await gate.failAll() } }
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        let a = UUID(), b = UUID()
        let first = try await coordinator.submit(request(f, id: a, revision: 0) { try await gate.run(1) })
        await gate.waitUntilStarted(1)
        let second = try await coordinator.submit(request(f, id: b, revision: 0) { try await gate.run(2) })
        await gate.waitUntilStarted(2)
        await gate.complete(2, .success(Data("B".utf8)))
        let bStatus = try await coordinator.waitUntilSettled(documentID: b)
        let bURL = try savedURL(bStatus, request: second, revision: 0)
        let aStatus = await coordinator.status(documentID: a)
        XCTAssertEqual(aStatus, .saving(request: first, revision: 0))
        await gate.complete(1, .success(Data("A".utf8)))
        let settledA = try await coordinator.waitUntilSettled(documentID: a)
        let aURL = try savedURL(settledA, request: first, revision: 0)
        XCTAssertNotEqual(aURL, bURL)
        XCTAssertEqual(try Data(contentsOf: aURL), Data("A".utf8))
        XCTAssertEqual(try Data(contentsOf: bURL), Data("B".utf8))
    }

    func testRestartRejectsOlderRevisionAcrossSlotsAndAdvancesRequestID() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        let first = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        let number = try await first.submit(request(f, id: id, revision: 10, slot: .jpg) { Data("ten".utf8) })
        _ = try await first.waitUntilSettled(documentID: id)
        let reopened = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        do {
            _ = try await reopened.submit(request(f, id: id, revision: 9, slot: .png) { Data("old".utf8) })
            XCTFail("A lower persisted revision must be rejected across slots")
        } catch { XCTAssertEqual(error as? ExportWriteError, .staleRequest) }
        let next = try await reopened.submit(request(f, id: id, revision: 10, slot: .png) { Data("ten-png".utf8) })
        XCTAssertGreaterThan(next, number)
        _ = try await reopened.waitUntilSettled(documentID: id)
    }

    func testLostPendingAssociationStillRejectsOlderDocumentRevision() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let id = UUID()
        var target: URL?
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts) { point, _, url in
            if case .afterRename = point { target = url; throw TestError.failed }
        }
        XCTAssertThrowsError(try writer.publish(documentID: id, createdAt: Date(timeIntervalSince1970: 0), slot: .jpg,
                                                destinationFolder: f.output, data: Data("new".utf8),
                                                stamp: ExportStamp(request: 8, documentRevision: 20)))
        try FileManager.default.removeItem(at: XCTUnwrap(target))
        let recovering = try OwnedExportWriter(receiptsRoot: f.receipts)
        XCTAssertNil(try recovering.existing(documentID: id, slot: .jpg))
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        do {
            _ = try await coordinator.submit(request(f, id: id, revision: 19) { Data("old".utf8) })
            XCTFail("Recovered association loss must not erase revision history")
        } catch { XCTAssertEqual(error as? ExportWriteError, .staleRequest) }
        let next = try await coordinator.submit(request(f, id: id, revision: 20) { Data("current".utf8) })
        XCTAssertGreaterThan(next, 8)
        _ = try await coordinator.waitUntilSettled(documentID: id)
    }

    func testSequenceOverflowRejectsBeforeCallingEncoder() async throws {
        let f = try Fixture()
        defer { f.remove() }
        var writer = try OwnedExportWriter(receiptsRoot: f.receipts)
        _ = try writer.publish(documentID: UUID(), createdAt: Date(timeIntervalSince1970: 0), slot: .png,
                               destinationFolder: f.output, data: Data([1]), stamp: ExportStamp(request: .max, documentRevision: 1))
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        do {
            _ = try await coordinator.submit(request(f, id: UUID(), revision: 1) {
                XCTFail("Rejected request must not invoke encoder")
                return Data([2])
            })
            XCTFail("Sequence overflow must reject")
        } catch { XCTAssertEqual(error as? ExportWriteError, .sequenceOverflow) }
    }

    func testStatusStreamAndCancelledWaiterDoNotCancelExport() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let gate = Gate()
        defer { Task { await gate.failAll() } }
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        let id = UUID()
        let stream = await coordinator.updates(documentID: id)
        var iterator = stream.makeAsyncIterator()
        let idle = await iterator.next()
        XCTAssertEqual(idle, .idle)
        let number = try await coordinator.submit(request(f, id: id, revision: 1) { try await gate.run(1) })
        await gate.waitUntilStarted(1)
        let saving = await iterator.next()
        XCTAssertEqual(saving, .saving(request: number, revision: 1))
        let waiter = Task { try await coordinator.waitUntilSettled(documentID: id) }
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Cancelled waiter must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let status = await coordinator.status(documentID: id)
        XCTAssertEqual(status, .saving(request: number, revision: 1))
        await gate.complete(1, .success(Data("saved".utf8)))
        let final = try await coordinator.waitUntilSettled(documentID: id)
        _ = try savedURL(final, request: number, revision: 1)
        let streamed = await iterator.next()
        XCTAssertEqual(streamed, final)
    }

    func testRegisteredWaiterCancellationDoesNotReleaseOrCancelEncoder() async throws {
        let f = try Fixture(); defer { f.remove() }
        let gate = Gate(); defer { Task { await gate.failAll() } }
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts), id = UUID()
        _ = try await coordinator.submit(request(f, id: id, revision: 1) { try await gate.run(1) })
        await gate.waitUntilStarted(1)
        let registered = XCTestExpectation(description: "settlement waiter registered")
        let waiter = Task { try await coordinator.waitUntilSettled(documentID: id, onWaiting: { registered.fulfill() }) }
        await fulfillment(of: [registered], timeout: 2)
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        guard case .saving = await coordinator.status(documentID: id) else { return XCTFail("Encoder was cancelled") }
        await gate.complete(1, .success(Data("saved".utf8)))
        guard case .saved = try await coordinator.waitUntilSettled(documentID: id) else { return XCTFail("Export did not finish") }
    }

    func testWriterOwnershipLossBecomesFailureWithoutOverwritingExternalData() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let coordinator = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        let id = UUID()
        let first = try await coordinator.submit(request(f, id: id, revision: 1) { Data("owned".utf8) })
        let firstStatus = try await coordinator.waitUntilSettled(documentID: id)
        let url = try savedURL(firstStatus, request: first, revision: 1)
        try Data("external".utf8).write(to: url)
        let second = try await coordinator.submit(request(f, id: id, revision: 2) { Data("must-not-write".utf8) })
        let final = try await coordinator.waitUntilSettled(documentID: id)
        guard case .failed(let number, _, _) = final else { return XCTFail("Expected ownership failure") }
        XCTAssertEqual(number, second)
        XCTAssertEqual(try Data(contentsOf: url), Data("external".utf8))
    }

    func testCoordinatorDoesNotRetainItselfAcrossPendingEncoder() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let gate = Gate()
        defer { Task { await gate.failAll() } }
        var coordinator: AutomaticExportCoordinator? = try AutomaticExportCoordinator(receiptsRoot: f.receipts)
        let observedCoordinator = { [weak coordinator] in coordinator }
        let id = UUID()
        _ = try await coordinator?.submit(request(f, id: id, revision: 1) { try await gate.run(1) })
        await gate.waitUntilStarted(1)
        coordinator = nil
        XCTAssertNil(observedCoordinator())
        await gate.complete(1, .success(Data("abandoned".utf8)))
    }

    private func request(_ f: Fixture, id: UUID, revision: UInt64, slot: ExportSlot = .png,
                         encode: @escaping @Sendable () async throws -> Data) -> ExportRequest {
        ExportRequest(documentID: id, revision: revision, slot: slot, createdAt: Date(timeIntervalSince1970: 0),
                      destinationFolder: f.output, encode: encode)
    }
    private func savedURL(_ status: ExportStatus, request: UInt64, revision: UInt64,
                          file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        guard case .saved(let number, let value, let url) = status else {
            XCTFail("Expected saved status, got \(status)", file: file, line: line)
            throw TestError.failed
        }
        XCTAssertEqual(number, request, file: file, line: line)
        XCTAssertEqual(value, revision, file: file, line: line)
        return url
    }
    private enum TestError: Error { case failed }
    private actor Gate {
        private var started: Set<Int> = []
        private var workers: [Int: CheckedContinuation<Data, Error>] = [:]
        private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
        func run(_ id: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                workers[id] = continuation
                started.insert(id)
                let waiters = startWaiters.removeValue(forKey: id) ?? []
                for waiter in waiters { waiter.resume() }
            }
        }
        func waitUntilStarted(_ id: Int) async {
            if started.contains(id) { return }
            await withCheckedContinuation { startWaiters[id, default: []].append($0) }
        }
        func complete(_ id: Int, _ result: Result<Data, Error>) {
            workers.removeValue(forKey: id)?.resume(with: result)
        }
        func failAll() {
            let pending = workers.values
            workers.removeAll()
            for continuation in pending { continuation.resume(throwing: TestError.failed) }
        }
    }
    private struct Fixture {
        let root: URL, receipts: URL, output: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-coordinator-tests-\(UUID().uuidString)")
            receipts = root.appendingPathComponent("receipts")
            output = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
