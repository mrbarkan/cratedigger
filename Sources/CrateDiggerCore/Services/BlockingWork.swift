import Foundation

/// Runs genuinely blocking work — subprocess spawn + `waitUntilExit` + a
/// `DispatchGroup.wait` for the pipe drain — **off the Swift cooperative pool**.
///
/// The pool is exactly `activeProcessorCount` wide and a parked thread can never
/// resume an `await`, so blocking on it starves the whole app: running ffprobe
/// straight from a task group once beachballed every scan (see
/// `LibraryScanService.probeQueue`). `Task.detached` does **not** help — detached
/// tasks run on that same pool. This queue is the escape hatch.
public enum BlockingWork {
    private static let queue = DispatchQueue(
        label: "com.cratedigger.blocking-work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
