import AppKit
import WebKit

/// One tab. It is either **live** (has a web view, and so a WebContent process)
/// or **sleeping** (just a URL, WebKit's saved interaction state, and a
/// snapshot). Sleeping tabs cost almost no memory.
@Observable
final class Tab: Identifiable {
    let id: UUID
    var url: URL?
    var title: String
    var lastActive: Date
    var favicon: NSImage?

    /// Non-nil while the tab is live. Only `TabLifecycle` sets this.
    var webView: WKWebView?
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var isSecure = false
    var isPlayingAudio = false
    var themeColor: NSColor?
    /// The link under the pointer, shown at the bottom of the page.
    var hoveredLink: URL?
    /// The consent platform whose cookie pop-up Feather declined on this page.
    var declinedCookies: String?
    /// The page's current audio/video, as reported by `MediaScript`.
    var media: MediaState?
    var isMuted = false
    /// The page looks like an article (Readability's quick check).
    var isReaderable = false
    var isReaderOpen = false
    /// Physical footprint of this tab's WebContent process, sampled by `MemoryMonitor`.
    var footprint: UInt64?
    /// The tab-list section this tab is in, if any.
    var groupID: UUID?
    /// What the page-layout script last saw (the site's own sidebar and so on).
    var layout: PageLayout?

    /// WebKit's back/forward list and scroll position, kept while sleeping.
    @ObservationIgnored var interactionState: Data?
    /// JPEG of the last rendering, shown while the tab wakes up.
    @ObservationIgnored var snapshotJPEG: Data?
    /// URL to load the next time the tab wakes up.
    @ObservationIgnored var pendingURL: URL?
    /// Set by `UnsavedInputTracker` when the user typed into the page without submitting.
    @ObservationIgnored var hasUnsavedInput = false
    /// Changes on document commit so pending unloads cannot discard a newer page.
    @ObservationIgnored var documentID = UUID()
    /// HTTP fallbacks to try if the current HTTPS load fails (see `URLInput`).
    @ObservationIgnored var fallbackURLs: [URL] = []
    @ObservationIgnored var controller: WebTabController?
    /// The frame whose player `media` describes; commands go there.
    @ObservationIgnored var mediaFrame: WKFrameInfo?
    @ObservationIgnored var mediaChanged = Date.distantPast
    /// Set while Feather has put this tab's video into picture-in-picture.
    @ObservationIgnored var autoPictureInPicture = false
    /// The Favorite this tab belongs to; such tabs show in the Favorites grid, not the tab list.
    var favoriteID: UUID?
    /// The user took this tab out of a group, so automatic grouping leaves it alone.
    @ObservationIgnored var noAutoGroup = false
    /// The page's meta description, from the page-layout script.
    @ObservationIgnored var summary: String?
    /// Apple Intelligence's "Topic: what you're doing" note for the page at `noteURL` (tab groups).
    @ObservationIgnored var note: String?
    @ObservationIgnored var noteURL: String?

    init(id: UUID = UUID(), url: URL?, title: String = "", lastActive: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.lastActive = lastActive
        self.pendingURL = url
        if let host = url?.host() {
            favicon = Favicons.shared.cached(host: host)
            if favicon == nil {
                Task { [weak self] in
                    let image = await Favicons.shared.loadCached(host: host)
                    if let self, self.url?.host() == host { self.favicon = image }
                }
            }
        }
    }

    convenience init(record: TabRecord) {
        self.init(id: record.id, url: record.url.flatMap(URL.init(string:)), title: record.title,
                  lastActive: record.lastActive)
        interactionState = record.interactionState
        favoriteID = record.favoriteID
        groupID = record.groupID
        noAutoGroup = record.noAutoGroup ?? false
        summary = record.summary
        note = record.note
        noteURL = record.noteURL
        if interactionState != nil { pendingURL = nil }
    }

    var isLive: Bool { webView != nil }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        return "New Tab"
    }

    /// State for saving; a live tab's history is read from its web view.
    func record() -> TabRecord {
        let state = (webView?.interactionState as? Data) ?? interactionState
        return TabRecord(id: id, url: url?.absoluteString, title: title, lastActive: lastActive, interactionState: state,
                         favoriteID: favoriteID, groupID: groupID, noAutoGroup: noAutoGroup ? true : nil,
                         summary: summary, note: note, noteURL: noteURL)
    }
}
