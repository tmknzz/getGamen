import Foundation
import XCTest
@testable import GetGamenCore

final class CaptureCountdownTests: XCTestCase {
    @MainActor
    func testZeroEmitsOnceWithoutReadingOrSleeping() async throws {
        let clock = ControlledClock()
        var labels: [Int] = []
        try await CaptureCountdown(clock: clock.clock).wait(seconds: 0) { labels.append($0) }
        XCTAssertEqual(labels, [0])
        XCTAssertEqual(clock.nowCalls, 0)
        XCTAssertTrue(clock.deadlines.isEmpty)
    }

    @MainActor
    func testOneSecondHasOneAbsoluteWakeAndNoRepeatedInitialLabel() async throws {
        let clock = ControlledClock(start: .seconds(7))
        defer { clock.failPending() }
        var labels: [Int] = []
        let task = Task { try await CaptureCountdown(clock: clock.clock).wait(seconds: 1) { labels.append($0) } }
        defer { task.cancel() }
        try await clock.waitForSleep(0)
        XCTAssertEqual(labels, [1])
        XCTAssertEqual(clock.deadlines, [.seconds(8)])
        clock.wake(at: .seconds(8))
        try await clock.complete(task)
        XCTAssertEqual(labels, [1, 0])
    }

    @MainActor
    func testTwelveSecondsUsesOriginalDeadlineAndEachAbsoluteBoundary() async throws {
        let clock = ControlledClock(start: .milliseconds(250))
        defer { clock.failPending() }
        var labels: [Int] = []
        let task = Task { try await CaptureCountdown(clock: clock.clock).wait(seconds: 12) { labels.append($0) } }
        defer { task.cancel() }
        let expected: [Duration] = [.milliseconds(1250), .milliseconds(2250), .milliseconds(3250),
                                    .milliseconds(4250), .milliseconds(5250), .milliseconds(6250),
                                    .milliseconds(7250), .milliseconds(8250), .milliseconds(9250),
                                    .milliseconds(10250), .milliseconds(11250), .milliseconds(12250)]
        for index in expected.indices {
            try await clock.waitForSleep(index)
            XCTAssertEqual(clock.deadlines[index], expected[index])
            clock.wake(at: expected[index])
        }
        try await clock.complete(task)
        XCTAssertEqual(labels, [12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0])
        XCTAssertEqual(clock.deadlines, expected)
    }

    @MainActor
    func testOversleepSkipsMissedLabelsAndNeverMovesFinalDeadline() async throws {
        let clock = ControlledClock()
        defer { clock.failPending() }
        var labels: [Int] = []
        let task = Task { try await CaptureCountdown(clock: clock.clock).wait(seconds: 10) { labels.append($0) } }
        defer { task.cancel() }
        try await clock.waitForSleep(0)
        clock.wake(at: .milliseconds(4250))
        try await clock.waitForSleep(1)
        XCTAssertEqual(labels, [10, 6])
        XCTAssertEqual(clock.deadlines, [.seconds(1), .seconds(5)])
        clock.wake(at: .milliseconds(9750))
        try await clock.waitForSleep(2)
        XCTAssertEqual(labels, [10, 6, 1])
        XCTAssertEqual(clock.deadlines[2], .seconds(10))
        clock.wake(at: .seconds(12))
        try await clock.complete(task)
        XCTAssertEqual(labels, [10, 6, 1, 0])
        XCTAssertEqual(clock.deadlines.count, 3)
    }

    @MainActor
    func testInvalidSecondsNeverReadsClockSleepsOrEmits() async {
        for seconds in [-1, 13, Int.min, Int.max] {
            let clock = ControlledClock()
            var labels: [Int] = []
            do {
                try await CaptureCountdown(clock: clock.clock).wait(seconds: seconds) { labels.append($0) }
                XCTFail("Invalid timer accepted")
            } catch { XCTAssertEqual(error as? CaptureCountdownError, .invalidSeconds) }
            XCTAssertEqual(clock.nowCalls, 0)
            XCTAssertTrue(clock.deadlines.isEmpty)
            XCTAssertTrue(labels.isEmpty)
        }
    }

    @MainActor
    func testAlreadyCancelledWaitEmitsNothingIncludingForZero() async {
        for seconds in [0, 1] {
            let clock = ControlledClock()
            var labels: [Int] = []
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await CaptureCountdown(clock: clock.clock).wait(seconds: seconds) { labels.append($0) }
            }
            do { try await clock.complete(task); XCTFail("Pre-cancelled wait returned success") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(labels.isEmpty)
            XCTAssertEqual(clock.nowCalls, 0)
            XCTAssertTrue(clock.deadlines.isEmpty)
        }
    }

    @MainActor
    func testCallbackCancellationIsCheckedBeforeSleepAndBeforeSuccessfulReturn() async {
        for seconds in [0, 3] {
            let clock = ControlledClock()
            var labels: [Int] = []
            let task = Task {
                try await CaptureCountdown(clock: clock.clock).wait(seconds: seconds) {
                    labels.append($0)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            do { try await clock.complete(task); XCTFail("Callback cancellation ignored") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(labels, [seconds])
            XCTAssertTrue(clock.deadlines.isEmpty)
        }
    }

    @MainActor
    func testCancellationFromIntermediateLabelStopsBeforeSecondSleep() async throws {
        let clock = ControlledClock()
        defer { clock.failPending() }
        var labels: [Int] = []
        let task = Task {
            try await CaptureCountdown(clock: clock.clock).wait(seconds: 3) {
                labels.append($0)
                if $0 == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        defer { task.cancel() }
        try await clock.waitForSleep(0)
        clock.wake(at: .seconds(1))
        do { try await clock.complete(task); XCTFail("Intermediate cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(labels, [3, 2])
        XCTAssertEqual(clock.deadlines, [.seconds(1)])
    }

    @MainActor
    func testCancellationFromTerminalCallbackDoesNotReturnSuccess() async throws {
        let clock = ControlledClock()
        defer { clock.failPending() }
        var labels: [Int] = []
        let task = Task {
            try await CaptureCountdown(clock: clock.clock).wait(seconds: 1) {
                labels.append($0)
                if $0 == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        defer { task.cancel() }
        try await clock.waitForSleep(0)
        clock.wake(at: .seconds(1))
        do { try await clock.complete(task); XCTFail("Terminal callback cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(labels, [1, 0])
    }

    @MainActor
    func testCancellationDuringSleepSuppressesLateSuccessAndReplacesLateError() async throws {
        for lateError in [false, true] {
            let clock = ControlledClock()
            defer { clock.failPending() }
            var labels: [Int] = []
            let task = Task { try await CaptureCountdown(clock: clock.clock).wait(seconds: 2) { labels.append($0) } }
            defer { task.cancel() }
            try await clock.waitForSleep(0)
            task.cancel()
            if lateError { clock.failPending() }
            else { clock.wake(at: .seconds(20)) }
            do { try await clock.complete(task); XCTFail("Cancelled sleep returned success") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(labels, [2])
            XCTAssertEqual(clock.deadlines, [.seconds(1)])
        }
    }

    @MainActor
    func testSleepErrorPropagatesWithoutTerminalZero() async throws {
        let clock = ControlledClock()
        defer { clock.failPending() }
        var labels: [Int] = []
        let task = Task { try await CaptureCountdown(clock: clock.clock).wait(seconds: 2) { labels.append($0) } }
        defer { task.cancel() }
        try await clock.waitForSleep(0)
        clock.failPending()
        do { try await clock.complete(task); XCTFail("Sleep error hidden") }
        catch { XCTAssertEqual(error as? Injected, .sleepFailed) }
        XCTAssertEqual(labels, [2])
    }

    @MainActor
    func testBackwardReadingBeforeSleepRejectsClock() async {
        var reads = 0
        var sleeps = 0
        var labels: [Int] = []
        let clock = CaptureCountdownClock(now: {
            reads += 1
            return reads == 1 ? .seconds(5) : .seconds(4)
        }, sleepUntil: { _ in sleeps += 1 })
        do { try await CaptureCountdown(clock: clock).wait(seconds: 2) { labels.append($0) }; XCTFail("Clock moved backwards") }
        catch { XCTAssertEqual(error as? CaptureCountdownError, .invalidClock) }
        XCTAssertEqual(labels, [2])
        XCTAssertEqual(sleeps, 0)
    }

    @MainActor
    func testNoProgressBackwardAndEarlySleepCompletionRejectWithoutRetrying() async throws {
        for instant in [Duration.zero, Duration.seconds(-1), Duration.milliseconds(500)] {
            let clock = ControlledClock(sleepLimit: 1)
            defer { clock.failPending() }
            var labels: [Int] = []
            let task = Task { try await CaptureCountdown(clock: clock.clock).wait(seconds: 2) { labels.append($0) } }
            defer { task.cancel() }
            try await clock.waitForSleep(0)
            clock.wake(at: instant)
            do { try await clock.complete(task); XCTFail("Broken sleep was accepted") }
            catch { XCTAssertEqual(error as? CaptureCountdownError, .invalidClock) }
            XCTAssertEqual(labels, [2])
            XCTAssertEqual(clock.deadlines.count, 1)
        }
    }

    private enum Injected: Error, Equatable { case sleepFailed, entryTimedOut }

    @MainActor private final class ControlledClock {
        var instant: Duration
        private(set) var nowCalls = 0
        private(set) var deadlines: [Duration] = []
        private let entries = (0..<13).map { XCTestExpectation(description: "Countdown sleep \($0) entered") }
        private var pending: CheckedContinuation<Void, Error>?
        private let sleepLimit: Int
        init(start: Duration = .zero, sleepLimit: Int = 12) { instant = start; self.sleepLimit = sleepLimit }
        var clock: CaptureCountdownClock {
            CaptureCountdownClock(now: { [self] in nowCalls += 1; return instant }, sleepUntil: { [self] deadline in
                precondition(pending == nil)
                let index = deadlines.count
                deadlines.append(deadline)
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    if index < sleepLimit { entries[index].fulfill() }
                    else { pending = nil; continuation.resume(throwing: Injected.sleepFailed) }
                }
            })
        }
        func waitForSleep(_ index: Int) async throws {
            guard deadlines.count <= index else { return }
            let result = await XCTWaiter.fulfillment(of: [entries[index]], timeout: 5)
            XCTAssertEqual(result, .completed)
            guard result == .completed else { failPending(); throw Injected.entryTimedOut }
        }
        func complete(_ task: Task<Void, Error>) async throws {
            let finished = XCTestExpectation(description: "Countdown task completed")
            let observer = Task {
                let result = await task.result
                finished.fulfill()
                return result
            }
            let outcome = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(outcome, .completed)
            guard outcome == .completed else {
                task.cancel()
                failPending()
                observer.cancel()
                throw Injected.entryTimedOut
            }
            let result = await observer.value
            try result.get()
        }
        func wake(at time: Duration) {
            instant = time
            let continuation = pending
            pending = nil
            continuation?.resume()
        }
        func failPending() {
            let continuation = pending
            pending = nil
            continuation?.resume(throwing: Injected.sleepFailed)
        }
    }
}
