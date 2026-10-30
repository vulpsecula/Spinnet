import Foundation

/// Coordinates status reads without blocking the main thread. Requests may
/// complete on any thread; accepted values are always applied on the main thread.
/// Call refresh and invalidate on the main thread.
final class BackgroundStatusRefresh<Value> {
    typealias Request = (@escaping (Value) -> Void) -> Void

    private let request: Request
    private let apply: (Value) -> Void
    private var generation: UInt = 0
    private var isReading = false
    private var needsRead = false

    init(request: @escaping Request, apply: @escaping (Value) -> Void) {
        self.request = request
        self.apply = apply
    }

    /// Repeated requests during a read are combined into one fresh read.
    func refresh() {
        precondition(Thread.isMainThread)
        generation &+= 1
        needsRead = true
        startIfNeeded()
    }

    /// A synchronous read or explicit change supersedes any pending result.
    func invalidate() {
        precondition(Thread.isMainThread)
        generation &+= 1
        needsRead = false
    }

    private func startIfNeeded() {
        guard needsRead, !isReading else { return }
        needsRead = false
        isReading = true
        let requestedGeneration = generation
        request { [weak self] value in
            let finish = { [weak self] in
                guard let self else { return }
                self.isReading = false
                if requestedGeneration == self.generation { self.apply(value) }
                self.startIfNeeded()
            }
            if Thread.isMainThread { finish() }
            else { DispatchQueue.main.async(execute: finish) }
        }
    }
}
