/// Serializes background persistence operations in the order callers enqueue them.
///
/// The writer deliberately continues after a failed operation. A newer complete snapshot can
/// still repair the persisted state, and callers receive each operation's own success value.
@MainActor
final class SerializedPersistenceWriter {
    private var tail: Task<Bool, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Bool) -> Task<Bool, Never> {
        let previous = tail
        let task = Task.detached(priority: .utility) {
            _ = await previous?.value
            return await operation()
        }
        tail = task
        return task
    }
}

/// Runs higher-level correction transactions one at a time, including across suspension
/// points. This prevents launch recovery and a newly edited correction from activating
/// conflicting rules for the same history item.
actor CorrectionTransactionCoordinator {
    private var isActive = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> T
    ) async -> T {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        if !isActive {
            isActive = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isActive = false
            return
        }
        waiters.removeFirst().resume()
    }
}
