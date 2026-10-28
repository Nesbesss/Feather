import Foundation

/// What the sleep policy needs to know about one tab. Gathered by `TabLifecycle`.
nonisolated struct TabFacts: Equatable, Sendable {
    var id: UUID
    var isLive: Bool
    var isVisible: Bool
    var lastActive: Date
    var isPlayingMedia = false
    var isCapturingMedia = false
    var hasUnsavedInput = false
    var isLoading = false
    var hasActivePopup = false
    var inVisibleSpace = true
    var footprint: UInt64?
}

nonisolated enum MemoryPressure: Sendable {
    case normal, warning, critical
}

nonisolated struct SleepDecision: Equatable, Sendable {
    enum Reason: String, Sendable {
        case idle, overBudget, memoryPressure, footprint, manual
    }

    var id: UUID
    var reason: Reason
}

/// Decides which live tabs to put to sleep. A sleeping tab has no web view and
/// therefore no WebContent process, which is where a browser's memory goes.
nonisolated struct SleepPolicy: Equatable, Sendable {
    /// Live web views allowed at once, including ones that can't be slept.
    var maxLiveTabs: Int
    /// Background tabs in a visible space sleep after this long without use.
    var sleepAfter: TimeInterval
    /// Tabs in spaces no window is showing sleep sooner.
    var hiddenSpaceSleepAfter: TimeInterval
    /// A background tab using more than this sleeps right away.
    var footprintLimit: UInt64?
    /// Whether system memory pressure puts every eligible tab to sleep.
    var sleepsUnderPressure = true
    /// Even an opted-in live-tab budget must allow time to switch back for a code.
    /// Only critical system pressure can bypass this grace period.
    var minimumBackgroundAge: TimeInterval = 60

    static let lean = SleepPolicy(maxLiveTabs: 4, sleepAfter: 5 * 60, hiddenSpaceSleepAfter: 60,
                                  footprintLimit: 1_500_000_000)
    static let balanced = SleepPolicy(maxLiveTabs: 8, sleepAfter: 20 * 60, hiddenSpaceSleepAfter: 5 * 60,
                                      footprintLimit: 2_500_000_000)
    static let never = SleepPolicy(maxLiveTabs: .max, sleepAfter: .infinity, hiddenSpaceSleepAfter: .infinity,
                                   footprintLimit: nil, sleepsUnderPressure: false)

    /// Battery saver: background tabs sleep in half the time and one in four
    /// fewer stay live. A policy that never sleeps tabs is left alone.
    func onBattery() -> SleepPolicy {
        guard self != .never else { return self }
        var policy = self
        policy.sleepAfter = sleepAfter / 2
        policy.hiddenSpaceSleepAfter = hiddenSpaceSleepAfter / 2
        if maxLiveTabs != .max { policy.maxLiveTabs = max(2, maxLiveTabs * 3 / 4) }
        return policy
    }

    /// Tabs to put to sleep, least recently used first. Visible tabs, tabs that
    /// play or capture media, load, own a popup, or contain edits are never chosen.
    func tabsToSleep(_ tabs: [TabFacts], now: Date, pressure: MemoryPressure = .normal) -> [SleepDecision] {
        let live = tabs.filter(\.isLive)
        let candidates = live
            .filter {
                !$0.isVisible && !$0.isPlayingMedia && !$0.isCapturingMedia && !$0.hasUnsavedInput
                    && !$0.isLoading && !$0.hasActivePopup
                    && (pressure == .critical || now.timeIntervalSince($0.lastActive) >= minimumBackgroundAge)
            }
            .sorted { $0.lastActive < $1.lastActive }

        if pressure != .normal && sleepsUnderPressure {
            return candidates.map { SleepDecision(id: $0.id, reason: .memoryPressure) }
        }

        var decisions: [SleepDecision] = []
        var chosen = Set<UUID>()
        for tab in candidates {
            let limit = tab.inVisibleSpace ? sleepAfter : hiddenSpaceSleepAfter
            if now.timeIntervalSince(tab.lastActive) >= limit {
                decisions.append(SleepDecision(id: tab.id, reason: .idle))
            } else if let cap = footprintLimit, let footprint = tab.footprint, footprint > cap {
                decisions.append(SleepDecision(id: tab.id, reason: .footprint))
            } else {
                continue
            }
            chosen.insert(tab.id)
        }

        var stillLive = live.count - decisions.count
        for tab in candidates where stillLive > maxLiveTabs && !chosen.contains(tab.id) {
            decisions.append(SleepDecision(id: tab.id, reason: .overBudget))
            stillLive -= 1
        }
        return decisions
    }
}
