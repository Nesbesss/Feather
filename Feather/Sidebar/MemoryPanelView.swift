import SwiftUI

/// Cmd-Opt-M: every process Feather uses, what it costs, and which tabs it serves.
struct MemoryPanelView: View {
    let state: BrowserState

    var body: some View {
        let memory = state.memory
        let tabs = state.allTabs
        let live = tabs.filter(\.isLive).count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(MemoryMonitor.format(memory.total)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                Text("total").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(live) live · \(tabs.count - live) sleeping")
                    Text("\(state.lifecycle.sleepCount) slept this session").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }

            Table(memory.usages) {
                TableColumn("Process") { usage in Text(usage.kind.rawValue) }
                    .width(min: 90, ideal: 100)
                TableColumn("Serving") { usage in Text(usage.label).lineLimit(1).truncationMode(.tail) }
                TableColumn("Memory") { usage in Text(MemoryMonitor.format(usage.footprint)).monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn("PID") { usage in Text(String(usage.id)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 50, ideal: 60)
            }

            if memory.unattributedProcesses > 0 {
                Text("Includes \(memory.unattributedProcesses) WebKit process(es) not tied to a tab, such as service workers.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack {
                Button("Unload Background Tabs") { Task { await state.lifecycle.sleepAllBackgroundTabs() } }
                    .help("Releases eligible background pages to save memory. Returning reloads them. Edits, loading, media, capture and sign-in popups stay protected.")
                Button("Simulate Memory Pressure") { Task { await state.lifecycle.evaluate(pressure: .critical) } }
                Spacer()
            }
            PoolStatusLine(status: FTWebKitSPI.status(ofPool: state.lifecycle.factory.processPool), sample: memory.total)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
    }
}

/// What WebKit reports about Feather's process pool, so the tuning is visible.
private struct PoolStatusLine: View {
    let status: [String: NSNumber]
    /// Changes on every memory sample, so the line refreshes with the table.
    let sample: UInt64

    var body: some View {
        if status.isEmpty {
            Text("WebKit process tuning unavailable on this macOS version")
        } else {
            let flag = { (key: String) in status[key].map { $0.boolValue ? "on" : "off" } ?? "?" }
            Text("Process cache \(flag("usesWebProcessCache")) (holding \(status["processCacheSize"]?.intValue ?? 0)) · "
                 + "prewarming \(flag("prewarmsProcessesAutomatically")) · page cache \(flag("pageCacheEnabled")) · "
                 + "aggressive suspension \(flag("suspendsWebProcessesAggressivelyOnMemoryPressure"))")
        }
    }
}
