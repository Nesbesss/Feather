import Observation

/// Runs `render` now and again whenever any observable property it read
/// changes. Changes made in the same turn of the run loop are coalesced.
/// Used only on the main actor; the change callback hops back to it.
final class ObservationLoop: @unchecked Sendable {
    private var cancelled = false

    init(_ render: @escaping () -> Void) {
        run(render)
    }

    func cancel() {
        cancelled = true
    }

    private func run(_ render: @escaping () -> Void) {
        guard !cancelled else { return }
        withObservationTracking(render) { [weak self] in
            let loop = self
            Task { @MainActor in loop?.run(render) }
        }
    }
}
