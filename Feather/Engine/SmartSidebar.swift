import WebKit

/// Decides, per site, whether the sidebar steps aside (Settings → Sidebar →
/// "Hide on sites that need the room"). The page-layout script says whether a
/// site seems to have its own sidebar or work like an app; Apple Intelligence
/// then confirms once per site, and the answer is remembered. ⌘S on a site
/// overrides both.
@Observable
final class SmartSidebar {
    /// Sites where some page looked like it has its own sidebar or works like an app, this session.
    private(set) var layoutHides: [String: Bool] = [:]
    /// Sites Apple Intelligence is being asked about; the sidebar stays as it is meanwhile.
    private(set) var pending: Set<String> = []

    @ObservationIgnored private unowned let state: BrowserState

    init(state: BrowserState) {
        self.state = state
    }

    static func host(of url: URL?) -> String? {
        guard let url, url.scheme == "https" || url.scheme == "http", let host = url.host() else { return nil }
        return Autocomplete.stripWWW(host.lowercased())
    }

    func handle(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let tab = state.tab(showing: message.webView),
              let layout = PageLayout(message: message.body), let host = Self.host(of: tab.url) else { return }
        tab.layout = layout
        if !layout.summary.isEmpty { tab.summary = layout.summary }
        if layout.suggestsHiding {
            if layoutHides[host] != true { layoutHides[host] = true }
        } else if layoutHides[host] == nil {
            layoutHides[host] = false
        }
        askIfNeeded(host: host, title: tab.title, layout: layout)
    }

    private func askIfNeeded(host: String, title: String, layout: PageLayout) {
        let settings = state.settings
        guard settings.sidebarMode == .smart, settings.sidebarUsesAI, layout.suggestsHiding,
              settings.sidebarAdvice[host] == nil, settings.sidebarOverrides[host] == nil, !pending.contains(host),
              AppleIntelligence.shared.isAvailable else { return }
        pending.insert(host)
        // The first answer can take a while as the model loads; don't hold the sidebar that long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.pending.remove(host) }
        Task {
            if let hide = await AppleIntelligence.shared.shouldHideSidebar(host: host, title: title, layout: layout) {
                settings.setSidebarAdvice(host, hide)
            }
            pending.remove(host)
        }
    }

    /// Whether `window`'s sidebar is hidden now. While Apple Intelligence is
    /// thinking about the front site, it keeps `previous`, so it moves at most once.
    func hides(in window: WindowState, width: Double, previous: Bool?) -> Bool {
        let settings = state.settings
        let host = Self.host(of: window.activeTab?.url)
        if settings.sidebarMode == .smart, let host, pending.contains(host), let previous { return previous }
        return SidebarPolicy.hides(mode: settings.sidebarMode, manuallyCollapsed: window.sidebarCollapsed, windowWidth: width,
                                   override: host.flatMap { settings.sidebarOverrides[$0] },
                                   advice: settings.sidebarUsesAI ? host.flatMap { settings.sidebarAdvice[$0] } : nil,
                                   layoutSuggestsHiding: host.flatMap { layoutHides[$0] })
    }
}
