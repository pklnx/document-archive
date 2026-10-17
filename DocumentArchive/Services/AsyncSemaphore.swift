import Foundation

/// A counting semaphore for Swift concurrency: at most `limit` holders at a time, the others
/// wait without blocking a thread.
///
/// - **FIFO:** waiters get the slot in the order they started waiting.
/// - **Cancellation:** a task cancelled while it waits is removed from the queue and `wait()`
///   throws `CancellationError`; it neither blocks the waiters behind it nor keeps a slot. A task
///   that was already handed the slot when it was cancelled keeps it and must signal as usual.
///
/// Use `withPermit` instead of pairing `wait` and `signal` by hand. `VisionGate` is the app's
/// user (#60).
final class AsyncSemaphore: Sendable {
    private let queue: Queue

    init(limit: Int) {
        precondition(limit > 0, "A semaphore needs at least one slot")
        queue = Queue(limit: limit)
    }

    /// Takes a slot, waiting for one when all are taken.
    /// - Throws: `CancellationError` when the task is cancelled before it got a slot.
    func wait() async throws {
        try await queue.wait()
    }

    /// Gives a slot back: to the oldest waiter, or to the pool when nobody waits.
    func signal() async {
        await queue.signal()
    }

    /// Runs `body` while holding a slot and gives it back afterwards, also when `body` throws.
    /// `body` runs on the caller's actor (`isolation`), never on the semaphore's.
    /// - Throws: `CancellationError` when cancelled while waiting (then `body` does not run), or
    ///   what `body` throws.
    func withPermit<T>(isolation: isolated (any Actor)? = #isolation,
                       _ body: () async throws -> T) async throws -> T {
        try await wait()
        do {
            let result = try await body()
            await signal()
            return result
        } catch {
            await signal()
            throw error
        }
    }

    /// The number of tasks waiting for a slot; for tests.
    var waiting: Int {
        get async { await queue.waiting }
    }

    /// The state: free slots and the waiters in FIFO order.
    private actor Queue {
        private let limit: Int
        private var available: Int
        private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
        private var nextID: UInt64 = 0

        init(limit: Int) {
            self.limit = limit
            available = limit
        }

        func wait() async throws {
            try Task.checkCancellation()
            if available > 0 {
                available -= 1
                return
            }
            let id = nextID
            nextID += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // Runs before the actor suspends, so `cancel(_:)` always finds the entry.
                    waiters.append((id, continuation))
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        func signal() {
            if waiters.isEmpty {
                precondition(available < limit, "signal() without a matching wait()")
                available += 1
            } else {
                waiters.removeFirst().continuation.resume()
            }
        }

        /// Removes a cancelled waiter. When it is no longer queued, it already got the slot and
        /// gives it back itself.
        private func cancel(_ id: UInt64) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }

        var waiting: Int { waiters.count }
    }
}
