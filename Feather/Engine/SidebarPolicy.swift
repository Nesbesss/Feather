import Foundation

/// How the sidebar makes room for websites (Settings → General → Sidebar).
nonisolated enum SidebarMode: String, CaseIterable, Identifiable, Sendable {
    /// Shown until you hide it with ⌘S.
    case show
    /// Steps aside on sites with their own sidebar or that work like apps, and in narrow windows.
    case smart
    /// Always hidden; slides in over the page from the left edge.
    case autoHide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .show: "Always show"
        case .smart: "Hide on sites that need the room"
        case .autoHide: "Always hide (slide in from the edge)"
        }
    }
}

/// What the page-layout script saw on a page.
nonisolated struct PageLayout: Equatable, Sendable {
    /// Width of the site's own navigation panel along the left edge, if it has one.
    var ownSidebarWidth: Int?
    /// A few labels from that panel ("Inbox", "Starred", …), for Apple Intelligence.
    var navLabels: [String] = []
    /// The page doesn't scroll itself and is full of controls, like a web app.
    var appLike = false
    /// The page's meta description (for tab groups, not the sidebar).
    var summary = ""

    /// Worth hiding Feather's sidebar for, before asking Apple Intelligence.
    var suggestsHiding: Bool { ownSidebarWidth != nil || appLike }

    init(ownSidebarWidth: Int? = nil, navLabels: [String] = [], appLike: Bool = false) {
        self.ownSidebarWidth = ownSidebarWidth
        self.navLabels = navLabels
        self.appLike = appLike
    }

    init?(message body: Any) {
        guard let body = body as? [String: Any] else { return nil }
        ownSidebarWidth = (body["sidebar"] as? Double).map { Int($0) } ?? (body["sidebar"] as? Int)
        navLabels = (body["labels"] as? [String] ?? []).prefix(10).map { String($0.prefix(40)) }
        appLike = body["app"] as? Bool ?? false
        summary = String((body["summary"] as? String ?? "").prefix(200))
    }
}

nonisolated enum SidebarPolicy {
    /// Below this window width, smart mode always gives the page the whole window.
    static let narrowWidth = 960.0

    /// Whether the sidebar is hidden for the site in the front tab.
    /// - Parameters:
    ///   - override: what you chose for this site with ⌘S (true = hidden); beats everything else.
    ///   - advice: Apple Intelligence's verdict for this site, once it has answered.
    ///   - layoutSuggestsHiding: whether any page of this site looked like it has its own sidebar.
    static func hides(mode: SidebarMode, manuallyCollapsed: Bool, windowWidth: Double,
                      override: Bool?, advice: Bool?, layoutSuggestsHiding: Bool?) -> Bool {
        switch mode {
        case .show:
            return manuallyCollapsed
        case .autoHide:
            return true
        case .smart:
            if let override { return override }
            if windowWidth < narrowWidth { return true }
            // Apple Intelligence only gets asked when the layout suggests hiding; it can say no.
            guard layoutSuggestsHiding == true else { return false }
            return advice ?? true
        }
    }
}
