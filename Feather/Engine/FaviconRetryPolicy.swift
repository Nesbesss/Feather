import Foundation

/// A failed icon should not cost another network request on every page of the
/// same site. Uses monotonic time, with no retry timer or persistent state.
nonisolated struct FaviconRetryPolicy {
    private var failures: [String: TimeInterval] = [:]
    let retryAfter: TimeInterval
    let capacity: Int

    init(retryAfter: TimeInterval = 60, capacity: Int = 256) {
        self.retryAfter = max(0, retryAfter)
        self.capacity = max(1, capacity)
    }

    mutating func shouldAttempt(_ host: String, now: TimeInterval) -> Bool {
        guard let retryAt = failures[host] else { return true }
        guard now >= retryAt else { return false }
        failures.removeValue(forKey: host)
        return true
    }

    mutating func failed(_ host: String, now: TimeInterval) {
        failures = failures.filter { $0.value > now }
        if failures[host] == nil, failures.count >= capacity,
           let oldest = failures.min(by: { $0.value < $1.value })?.key {
            failures.removeValue(forKey: oldest)
        }
        failures[host] = now + retryAfter
    }

    mutating func succeeded(_ host: String) {
        failures.removeValue(forKey: host)
    }
}
