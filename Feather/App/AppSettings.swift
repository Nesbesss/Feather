import Foundation

enum EfficiencyProfile: String, CaseIterable, Identifiable {
    /// Smaller live-tab budget when optional unloading is enabled.
    case lean
    /// Larger live-tab budget when optional unloading is enabled.
    case balanced
    /// Never unloads tabs, including when automatic unloading is enabled.
    case unlimited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lean: "Lean"
        case .balanced: "Balanced"
        case .unlimited: "Unlimited (no sleeping)"
        }
    }

    var basePolicy: SleepPolicy {
        switch self {
        case .lean: .lean
        case .balanced: .balanced
        case .unlimited: .never
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, kagi, ecosia, bing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        case .bing: "Bing"
        }
    }

    var template: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .duckDuckGo: "https://duckduckgo.com/?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        }
    }
}

/// User preferences, persisted in UserDefaults. Launch arguments override them
/// (for example `-FeatherProfile unlimited`), which the benchmark relies on.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    /// Off while loading, so defaults and launch-argument overrides are never written back.
    @ObservationIgnored private var persists = false

    var profile: EfficiencyProfile {
        didSet {
            guard persists else { return }
            defaults.set(profile.rawValue, forKey: Keys.profile)
            sleepAfterMinutes = profile.basePolicy.sleepAfter.isFinite ? profile.basePolicy.sleepAfter / 60 : 0
            maxLiveTabs = profile.basePolicy.maxLiveTabs == .max ? 0 : profile.basePolicy.maxLiveTabs
        }
    }
    /// 0 means never.
    var sleepAfterMinutes: Double { didSet { if persists { defaults.set(sleepAfterMinutes, forKey: Keys.sleepAfter) } } }
    /// 0 means unlimited.
    var maxLiveTabs: Int { didSet { if persists { defaults.set(maxLiveTabs, forKey: Keys.maxLive) } } }
    /// Retain running pages by default. Unloading destroys their DOM and JavaScript state.
    var automaticallyUnloadTabs: Bool {
        didSet { if persists { defaults.set(automaticallyUnloadTabs, forKey: Keys.automaticallyUnload) } }
    }
    var lazyBackgroundTabs: Bool { didSet { if persists { defaults.set(lazyBackgroundTabs, forKey: Keys.lazyBackground) } } }
    var blockContent: Bool { didSet { if persists { defaults.set(blockContent, forKey: Keys.blockContent) } } }
    var showYouTubeAdCatchPopups: Bool { didSet { if persists { defaults.set(showYouTubeAdCatchPopups, forKey: Keys.youTubeAdCatchPopups) } } }
    /// Clicking outside the tour stays quiet unless the user chooses otherwise.
    var clickSoundScope: ClickSoundScope { didSet { if persists { defaults.set(clickSoundScope.rawValue, forKey: Keys.clickSoundScope) } } }
    /// Typing feedback has its own scope, independent of mouse click sounds.
    var typingSoundScope: ClickSoundScope { didSet { if persists { defaults.set(typingSoundScope.rawValue, forKey: Keys.typingSoundScope) } } }
    var declineCookiePopups: Bool { didSet { if persists { defaults.set(declineCookiePopups, forKey: Keys.declineCookies) } } }
    var cleanLinks: Bool { didSet { if persists { defaults.set(cleanLinks, forKey: Keys.cleanLinks) } } }
    var autoPictureInPicture: Bool { didSet { if persists { defaults.set(autoPictureInPicture, forKey: Keys.autoPiP) } } }
    var readerFontSize: Double { didSet { if persists { defaults.set(readerFontSize, forKey: Keys.readerFontSize) } } }
    var skipSponsors: Bool { didSet { if persists { defaults.set(skipSponsors, forKey: Keys.skipSponsors) } } }
    var youtubeQuality: YouTubeQuality { didSet { if persists { defaults.set(youtubeQuality.rawValue, forKey: Keys.youtubeQuality) } } }
    var batterySaver: Bool { didSet { if persists { defaults.set(batterySaver, forKey: Keys.batterySaver) } } }
    var blockAutoplay: Bool { didSet { if persists { defaults.set(blockAutoplay, forKey: Keys.blockAutoplay) } } }
    var searchEngine: SearchEngine { didSet { if persists { defaults.set(searchEngine.rawValue, forKey: Keys.searchEngine) } } }
    var allowlistedHosts: [String] { didSet { if persists { defaults.set(allowlistedHosts, forKey: Keys.allowlist) } } }
    var showMemoryInSidebar: Bool { didSet { if persists { defaults.set(showMemoryInSidebar, forKey: Keys.showMemory) } } }
    var sidebarWidth: Double { didSet { if persists { defaults.set(sidebarWidth, forKey: Keys.sidebarWidth) } } }
    /// Sites (registrable domains) the user said never to save passwords for.
    var neverSavePasswordSites: [String] { didSet { if persists { defaults.set(neverSavePasswordSites, forKey: Keys.neverSave) } } }
    /// Unpinned tabs untouched this long move to the archive; 0 means never.
    var archiveAfterHours: Double { didSet { if persists { defaults.set(archiveAfterHours, forKey: Keys.archiveAfter) } } }
    /// Prototype: Liquid Glass sidebar, command bar, and banners over a tinted, see-through window.
    var glassInterface: Bool { didSet { if persists { defaults.set(glassInterface, forKey: Keys.glass) } } }
    /// The user dismissed the suggested sites under an empty Favorites grid.
    var hideFavoriteSuggestions: Bool {
        didSet { if persists { defaults.set(hideFavoriteSuggestions, forKey: Keys.hideFavoriteSuggestions) } }
    }
    var sidebarMode: SidebarMode { didSet { if persists { defaults.set(sidebarMode.rawValue, forKey: Keys.sidebarMode) } } }
    /// Smart sidebar: ask Apple Intelligence about sites that seem to have their own sidebar.
    var sidebarUsesAI: Bool { didSet { if persists { defaults.set(sidebarUsesAI, forKey: Keys.sidebarUsesAI) } } }
    /// Your ⌘S choices per site (host without "www."): true = hidden.
    var sidebarOverrides: [String: Bool] { didSet { if persists { defaults.set(sidebarOverrides, forKey: Keys.sidebarOverrides) } } }
    /// Apple Intelligence's verdicts per site, so each site is asked about once.
    var sidebarAdvice: [String: Bool] { didSet { if persists { defaults.set(sidebarAdvice, forKey: Keys.sidebarAdvice) } } }
    var autoGroupTabs: Bool { didSet { if persists { defaults.set(autoGroupTabs, forKey: Keys.autoGroupTabs) } } }
    /// Tint the window frame and sidebar with the site's theme color, like Safari's tab bar.
    var matchSiteColor: Bool { didSet { if persists { defaults.set(matchSiteColor, forKey: Keys.matchSiteColor) } } }
    /// Which Settings pane is showing; not saved.
    var settingsPane = "general"

    init() {
        let profile = EfficiencyProfile(rawValue: defaults.string(forKey: Keys.profile) ?? "") ?? .lean
        self.profile = profile
        sleepAfterMinutes = defaults.object(forKey: Keys.sleepAfter) as? Double ?? profile.basePolicy.sleepAfter / 60
        maxLiveTabs = defaults.object(forKey: Keys.maxLive) as? Int ?? profile.basePolicy.maxLiveTabs
        automaticallyUnloadTabs = PreferenceValue.bool(forKey: Keys.automaticallyUnload, in: defaults, default: false)
        lazyBackgroundTabs = defaults.object(forKey: Keys.lazyBackground) as? Bool ?? true
        blockContent = PreferenceValue.bool(forKey: Keys.blockContent, in: defaults, default: true)
        showYouTubeAdCatchPopups = PreferenceValue.bool(forKey: Keys.youTubeAdCatchPopups, in: defaults, default: false)
        clickSoundScope = ClickSoundScope(preferenceValue: defaults.string(forKey: Keys.clickSoundScope))
        typingSoundScope = ClickSoundScope(preferenceValue: defaults.string(forKey: Keys.typingSoundScope))
        blockAutoplay = defaults.object(forKey: Keys.blockAutoplay) as? Bool ?? false
        declineCookiePopups = defaults.object(forKey: Keys.declineCookies) as? Bool ?? true
        cleanLinks = defaults.object(forKey: Keys.cleanLinks) as? Bool ?? true
        autoPictureInPicture = defaults.object(forKey: Keys.autoPiP) as? Bool ?? true
        readerFontSize = defaults.object(forKey: Keys.readerFontSize) as? Double ?? 19
        skipSponsors = defaults.object(forKey: Keys.skipSponsors) as? Bool ?? true
        batterySaver = defaults.object(forKey: Keys.batterySaver) as? Bool ?? true
        youtubeQuality = YouTubeQuality(rawValue: defaults.string(forKey: Keys.youtubeQuality) ?? "") ?? .q1080
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .google
        allowlistedHosts = defaults.stringArray(forKey: Keys.allowlist) ?? []
        showMemoryInSidebar = defaults.object(forKey: Keys.showMemory) as? Bool ?? true
        sidebarWidth = defaults.object(forKey: Keys.sidebarWidth) as? Double ?? 240
        neverSavePasswordSites = defaults.stringArray(forKey: Keys.neverSave) ?? []
        archiveAfterHours = defaults.object(forKey: Keys.archiveAfter) as? Double ?? 12
        // bool(forKey:) also reads "YES"/"1" from launch arguments (-FeatherGlassInterface YES).
        glassInterface = defaults.object(forKey: Keys.glass) != nil && defaults.bool(forKey: Keys.glass)
        hideFavoriteSuggestions = defaults.object(forKey: Keys.hideFavoriteSuggestions) != nil
            && defaults.bool(forKey: Keys.hideFavoriteSuggestions)
        sidebarMode = SidebarMode(rawValue: defaults.string(forKey: Keys.sidebarMode) ?? "") ?? .smart
        sidebarUsesAI = defaults.object(forKey: Keys.sidebarUsesAI) == nil || defaults.bool(forKey: Keys.sidebarUsesAI)
        sidebarOverrides = defaults.dictionary(forKey: Keys.sidebarOverrides) as? [String: Bool] ?? [:]
        sidebarAdvice = defaults.dictionary(forKey: Keys.sidebarAdvice) as? [String: Bool] ?? [:]
        autoGroupTabs = defaults.object(forKey: Keys.autoGroupTabs) == nil || defaults.bool(forKey: Keys.autoGroupTabs)
        matchSiteColor = defaults.object(forKey: Keys.matchSiteColor) == nil || defaults.bool(forKey: Keys.matchSiteColor)
        if profile == .unlimited {
            sleepAfterMinutes = 0
            maxLiveTabs = 0
        }
        persists = true
    }

    var policy: SleepPolicy {
        guard automaticallyUnloadTabs, profile != .unlimited else { return .never }
        var policy = profile.basePolicy
        policy.sleepAfter = sleepAfterMinutes > 0 ? sleepAfterMinutes * 60 : .infinity
        if sleepAfterMinutes == 0 { policy.hiddenSpaceSleepAfter = .infinity }
        policy.maxLiveTabs = maxLiveTabs > 0 ? maxLiveTabs : .max
        return policy
    }

    func isAllowlisted(_ host: String?) -> Bool {
        YouTubeBlockingPolicy.isAllowlisted(host, hosts: allowlistedHosts)
    }

    func setAllowlisted(_ host: String, _ allowed: Bool) {
        allowlistedHosts = YouTubeBlockingPolicy.updatingAllowlist(allowlistedHosts, host: host, allowed: allowed)
    }

    /// nil forgets your choice for the site.
    func setSidebarOverride(_ host: String, hidden: Bool?) {
        sidebarOverrides[host] = hidden
    }

    func setSidebarAdvice(_ host: String, _ hide: Bool) {
        if sidebarAdvice.count > 500 { sidebarAdvice.removeAll() }
        sidebarAdvice[host] = hide
    }

    func neverSavesPasswords(for host: String) -> Bool {
        neverSavePasswordSites.contains(SiteMatcher.registrableDomain(host))
    }

    func setNeverSavePasswords(for host: String, _ never: Bool = true) {
        let site = SiteMatcher.registrableDomain(host)
        neverSavePasswordSites.removeAll { $0 == site }
        if never { neverSavePasswordSites.append(site) }
    }

    private enum Keys {
        static let profile = "FeatherProfile"
        static let sleepAfter = "FeatherSleepAfterMinutes"
        static let maxLive = "FeatherMaxLiveTabs"
        static let automaticallyUnload = "FeatherAutomaticallyUnloadTabs"
        static let lazyBackground = "FeatherLazyBackgroundTabs"
        static let blockContent = "FeatherBlockContent"
        static let youTubeAdCatchPopups = "FeatherShowYouTubeAdCatchPopups"
        static let clickSoundScope = "FeatherClickSoundScope"
        static let typingSoundScope = "FeatherTypingSoundScope"
        static let blockAutoplay = "FeatherBlockAutoplay"
        static let declineCookies = "FeatherDeclineCookiePopups"
        static let cleanLinks = "FeatherCleanLinks"
        static let autoPiP = "FeatherAutoPictureInPicture"
        static let readerFontSize = "FeatherReaderFontSize"
        static let skipSponsors = "FeatherSkipSponsors"
        static let batterySaver = "FeatherBatterySaver"
        static let youtubeQuality = "FeatherYouTubeQuality"
        static let searchEngine = "FeatherSearchEngine"
        static let allowlist = "FeatherAllowlistedHosts"
        static let showMemory = "FeatherShowMemory"
        static let sidebarWidth = "FeatherSidebarWidth"
        static let neverSave = "FeatherNeverSavePasswordSites"
        static let archiveAfter = "FeatherArchiveAfterHours"
        static let glass = "FeatherGlassInterface"
        static let hideFavoriteSuggestions = "FeatherHideFavoriteSuggestions"
        static let sidebarMode = "FeatherSidebarMode"
        static let sidebarUsesAI = "FeatherSidebarUsesAI"
        static let sidebarOverrides = "FeatherSidebarOverrides"
        static let sidebarAdvice = "FeatherSidebarAdvice"
        static let autoGroupTabs = "FeatherAutoGroupTabs"
        static let matchSiteColor = "FeatherMatchSiteColor"
    }
}
