import AppKit
import WebKit

/// Samples the physical footprint (what Activity Monitor calls "Memory") of
/// Feather and every WebKit process it uses, attributing WebContent processes
/// to tabs. Samples every 3 s while Feather is frontmost, every 30 s otherwise.
@Observable
final class MemoryMonitor {
    struct Usage: Identifiable, Equatable {
        enum Kind: String {
            case app = "Feather"
            case webContent = "Web Content"
            case network = "Networking"
            case gpu = "GPU"
            case helper = "Helper"
        }

        var id: pid_t
        var kind: Kind
        var label: String
        var footprint: UInt64
    }

    private(set) var total: UInt64 = 0
    private(set) var usages: [Usage] = []
    /// WebContent processes counted in the total that no tab accounts for (e.g. service workers).
    private(set) var unattributedProcesses = 0
    static let unattributedLabel = "Not attributed to a tab"
    @ObservationIgnored weak var state: BrowserState?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var interval: TimeInterval = 0

    func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(every: 3) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(every: 30) }
        }
        schedule(every: 3)
    }

    private func schedule(every seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = seconds / 5
        sample()
    }

    func sample() {
        guard let state else { return }
        var byPID: [pid_t: Usage] = [:]
        var unavailablePIDs = Set<pid_t>()
        func footprint(of pid: pid_t) -> UInt64? {
            if let known = byPID[pid] { return known.footprint }
            guard !unavailablePIDs.contains(pid) else { return nil }
            let result = Self.footprint(of: pid)
            if result == nil { unavailablePIDs.insert(pid) }
            return result
        }
        let own = getpid()
        byPID[own] = Usage(id: own, kind: .app, label: "Feather", footprint: footprint(of: own) ?? 0)

        for tab in state.liveTabs {
            guard let webView = tab.webView else { continue }
            tab.isPlayingAudio = FTWebKitSPI.isPlayingAudio(webView)
            let pid = FTWebKitSPI.webProcessIdentifier(for: webView)
            // Several tabs can share a WebContent process. Its footprint is
            // identical for all of them in this sample; probe it only once.
            guard pid > 0, let footprint = footprint(of: pid) else {
                tab.footprint = nil
                continue
            }
            tab.footprint = footprint
            if var existing = byPID[pid] {
                existing.label += ", " + tab.displayTitle
                byPID[pid] = existing
            } else {
                byPID[pid] = Usage(id: pid, kind: .webContent, label: tab.displayTitle, footprint: footprint)
            }
        }
        // Everything else macOS holds Feather responsible for: shader compilers,
        // audio helpers, unattributed WebContent processes. Matches Activity Monitor.
        // Discover Networking/GPU here too: WebKit's testing PID getters can
        // trap when a local-file page has not started those processes.
        for pid in Self.processesResponsible(to: own) where byPID[pid] == nil {
            guard let footprint = footprint(of: pid) else { continue }
            let name = Self.processName(pid)
            let kind: Usage.Kind = name.hasSuffix(".WebContent") ? .webContent : name.hasSuffix(".Networking") ? .network
                : name.hasSuffix(".GPU") ? .gpu : .helper
            byPID[pid] = Usage(id: pid, kind: kind, label: kind == .webContent ? Self.unattributedLabel : name,
                               footprint: footprint)
        }

        unattributedProcesses = byPID.values.filter { $0.label == Self.unattributedLabel }.count
        let sorted = byPID.values.sorted { ($0.kind == .app ? 0 : 1, -Int64($0.footprint)) < ($1.kind == .app ? 0 : 1, -Int64($1.footprint)) }
        if sorted != usages { usages = sorted }
        let sum = sorted.reduce(0) { $0 + $1.footprint }
        if sum != total { total = sum }
    }

    /// Physical footprint in bytes, as Activity Monitor reports it.
    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: ResponsibleFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                                     "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFunction.self) }

    /// Processes whose responsible process is `root` (how Activity Monitor groups them).
    static func processesResponsible(to root: pid_t) -> [pid_t] {
        guard let responsibleFor else { return [] }
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, filled))).filter { $0 > 0 && $0 != root && responsibleFor($0) == root }
    }

    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "process \(pid)"
    }

    static func format(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : String(format: "%.0f MB", megabytes)
    }
}
