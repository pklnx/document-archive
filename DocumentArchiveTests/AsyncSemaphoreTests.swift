import Foundation
import Synchronization
import Testing
@testable import DocumentArchive

/// The semaphore behind `VisionGate` (#60): FIFO, cancellation-safe, no deadlock.
@Suite(.timeLimit(.minutes(1))) struct AsyncSemaphoreTests {
    /// Waits until `count` tasks are queued, so the next waiter is known to be behind them.
    private func waitUntilQueued(_ semaphore: AsyncSemaphore, _ count: Int) async throws {
        let deadline = ContinuousClock.now + TestSupport.scaled(.seconds(10))
        while await semaphore.waiting != count {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(count) waiters expected, \(await semaphore.waiting) queued")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func waitersGetTheSlotInTheOrderTheyAsked() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        try await semaphore.wait()
        let order = Recorder<Int>()
        var tasks: [Task<Void, Error>] = []
        for index in 0..<6 {
            tasks.append(Task {
                try await semaphore.wait()
                order.append(index)
                await semaphore.signal()
            })
            try await waitUntilQueued(semaphore, index + 1)
        }

        await semaphore.signal()
        for task in tasks { try await task.value }
        #expect(order.values == Array(0..<6))
        #expect(await semaphore.waiting == 0)
    }

    /// A waiter cancelled in the queue throws, does not block the ones behind it and does not
    /// keep the slot.
    @Test func cancelledWaiterLeavesTheQueueAndTheSlot() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        try await semaphore.wait()
        let cancelled = Task { try await semaphore.wait() }
        try await waitUntilQueued(semaphore, 1)
        let next = Task {
            try await semaphore.wait()
            await semaphore.signal()
            return true
        }
        try await waitUntilQueued(semaphore, 2)

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await waitUntilQueued(semaphore, 1)

        await semaphore.signal()
        #expect(try await next.value)
        // The slot is free again: another holder gets it at once.
        #expect(try await semaphore.withPermit { 42 } == 42)
        #expect(await semaphore.waiting == 0)
    }

    @Test func cancelledTaskDoesNotTakeAFreeSlot() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await semaphore.withPermit { _ = Issue.record("the body must not run") }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await semaphore.withPermit { "free" } == "free")
    }

    /// A holder cancelled while it holds the slot finishes its body and still gives it back.
    @Test func holderCancelledInsideTheBodyStillReleases() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        let entered = Recorder<Bool>()
        let holder = Task {
            try await semaphore.withPermit {
                entered.append(true)
                while !Task.isCancelled { await Task.yield() }
            }
        }
        while entered.values.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        holder.cancel()
        try await holder.value
        #expect(try await semaphore.withPermit { true })
    }

    struct BodyError: Error {}

    /// Counts the holders of a semaphore from many tasks.
    final class Holders: Sendable {
        private let state = Mutex((inFlight: 0, maximum: 0, finished: 0))

        func enter() { state.withLock { $0.inFlight += 1; $0.maximum = max($0.maximum, $0.inFlight) } }
        func leave() { state.withLock { $0.inFlight -= 1; $0.finished += 1 } }
        var counts: (inFlight: Int, maximum: Int, finished: Int) { state.withLock { $0 } }
    }

    @Test func withPermitReleasesWhenTheBodyThrows() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        await #expect(throws: BodyError.self) {
            try await semaphore.withPermit { throw BodyError() }
        }
        #expect(try await semaphore.withPermit { 1 } == 1)
    }

    /// Many tasks at once: never more holders than the limit, and every task finishes.
    @Test(arguments: [1, 3])
    func manyConcurrentHoldersStayWithinTheLimit(limit: Int) async throws {
        let semaphore = AsyncSemaphore(limit: limit)
        let state = Holders()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try await semaphore.withPermit {
                        state.enter()
                        try await Task.sleep(for: .microseconds(200))
                        state.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let result = state.counts
        #expect(result.finished == 100)
        #expect(result.maximum <= limit)
        #expect(result.maximum >= 1)
        #expect(await semaphore.waiting == 0)
    }

    @MainActor private static var touchedOnTheMainActor = 0

    /// The body runs on the caller's actor, not on the semaphore's: it changes main-actor state
    /// without `await`.
    @MainActor @Test func bodyRunsOnTheCallersActor() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        let value = try await semaphore.withPermit {
            Self.touchedOnTheMainActor += 1
            return Self.touchedOnTheMainActor
        }
        #expect(value >= 1)
    }
}
