import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general, appearance, sidebar, privacy, performance, media, passwords, extensions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .sidebar: "Sidebar & Tabs"
        case .privacy: "Privacy"
        case .performance: "Performance"
        case .media: "Media & Sounds"
        case .passwords: "Passwords"
        case .extensions: "Extensions"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .sidebar: "sidebar.left"
        case .privacy: "hand.raised"
        case .performance: "leaf"
        case .media: "speaker.wave.2"
        case .passwords: "key"
        case .extensions: "puzzlepiece.extension"
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    private let extensionStore: WebExtensionStore
    @State private var extensionState = ExtensionSettingsState()

    init(settings: AppSettings, extensionStore: WebExtensionStore? = nil) {
        self.settings = settings
        self.extensionStore = extensionStore ?? .shared
    }

    private var selected: SettingsDestination { SettingsDestination(rawValue: settings.settingsPane) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    if let icon = NSImage(named: NSImage.Name("AppIcon")) {
                        Image(nsImage: icon).resizable().frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "leaf.fill").font(.system(size: 24)).foregroundStyle(SettingsTheme.accent)
                            .frame(width: 36, height: 36)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Feather").font(.system(size: 15, weight: .semibold))
                        Text("Settings").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(SettingsDestination.allCases) { destination in
                            SettingsNavigationItem(destination: destination, selected: selected == destination) {
                                settings.settingsPane = destination.rawValue
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Spacer(minLength: 0)
                Text("Changes save automatically")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
            .padding(14)
            .frame(width: 204)
            .background(.regularMaterial)
            Rectangle().fill(SettingsTheme.border).frame(width: 0.5)
            Group {
                switch selected {
                case .passwords: PasswordsSettingsView(settings: settings)
                case .extensions: ExtensionsSettingsView(store: extensionStore, state: extensionState)
                default: GeneralSettingsView(settings: settings, destination: selected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(selected)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 560, idealHeight: 680)
        .background(SettingsTheme.pageBackground)
        .tint(SettingsTheme.accent)
    }
}

private struct SettingsNavigationItem: View {
    let destination: SettingsDestination
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? SettingsTheme.accent : .secondary)
                    .frame(width: 19)
                Text(destination.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selected ? SettingsTheme.accent.opacity(0.13) : hovered ? Color.primary.opacity(0.045) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(destination.title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier("feather.settings.category.\(destination.rawValue)")
    }
}

private struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    let destination: SettingsDestination

    var body: some View {
        switch destination {
        case .general: general
        case .appearance: appearance
        case .sidebar: sidebar
        case .privacy: privacy
        case .performance: performance
        default: media
        }
    }

    private var general: some View {
        SettingsPage(title: "General", subtitle: "Your everyday browsing preferences.") {
            DefaultBrowserCard()
            SettingsCard(title: "Search") {
                SettingsRow(title: "Search engine", subtitle: "Used when you search from the address bar.") {
                    Picker("Search engine", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 170)
                }
            }
            SettingsCard(title: "Getting started") {
                SettingsRow(title: "A quick tour of Feather", subtitle: "Find your way around tabs, spaces, and search.") {
                    Button("Take the Tour") {
                        NSApp.sendAction(#selector(AppDelegate.showWelcomeGuide(_:)), to: nil, from: nil)
                    }
                    .accessibilityIdentifier("feather.settings.welcome-guide")
                }
            }
        }
    }

    private var appearance: some View {
        SettingsPage(title: "Appearance", subtitle: "Choose how your browser looks.") {
            SettingsCard(title: "Window") {
                SettingsToggle(title: "Liquid Glass", subtitle: "Translucent surfaces for the sidebar, search, and banners. Preview feature.", isOn: $settings.glassInterface)
                SettingsDivider()
                SettingsToggle(title: "Use the website’s colors", subtitle: "Tint the window and sidebar to match the page.", isOn: $settings.matchSiteColor)
            }
            SettingsCard(title: "Sidebar details") {
                SettingsToggle(title: "Show memory usage", subtitle: "Keep Feather’s memory use visible in the sidebar.", isOn: $settings.showMemoryInSidebar)
                SettingsDivider()
                SettingsToggle(title: "Suggest Favorites", subtitle: "Show useful sites while your Favorites grid is empty.", isOn: Binding(get: { !settings.hideFavoriteSuggestions }, set: { settings.hideFavoriteSuggestions = !$0 }))
            }
        }
    }

    private var sidebar: some View {
        SettingsPage(title: "Sidebar & Tabs", subtitle: "Control the sidebar and organize your tabs.") {
            SettingsCard(title: "Sidebar behavior") {
                SettingsRow(title: "Show the sidebar") {
                    Picker("Show the sidebar", selection: $settings.sidebarMode) {
                        Text("Always").tag(SidebarMode.show)
                        Text("When there’s room").tag(SidebarMode.smart)
                        Text("On hover").tag(SidebarMode.autoHide)
                    }.labelsHidden().frame(width: 175)
                }
                if settings.sidebarMode == .smart {
                    SettingsDivider()
                    SettingsToggle(title: "Let Apple Intelligence help", subtitle: "Choose when a website needs the full window.", isOn: $settings.sidebarUsesAI)
                        .disabled(!AppleIntelligence.shared.isAvailable)
                }
            }
            SettingsNote("Touch the left edge to reveal a hidden sidebar. Press ⌘S on a website to remember your choice.", systemImage: "sidebar.left")
            if !settings.sidebarAdvice.isEmpty {
                SettingsCard {
                    SettingsRow(title: "Learned website preferences", subtitle: "\(settings.sidebarAdvice.count) sites decided by Apple Intelligence.") {
                        Button("Reset") { settings.sidebarAdvice = [:] }
                    }
                }
            }
            if !settings.sidebarOverrides.isEmpty {
                SettingsCard(title: "Your website choices") {
                    ForEach(settings.sidebarOverrides.keys.sorted(), id: \.self) { host in
                        SettingsRow(title: host, subtitle: settings.sidebarOverrides[host] == true ? "Sidebar hidden" : "Sidebar shown") {
                            Button { settings.setSidebarOverride(host, hidden: nil) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Forget sidebar preference for \(host)")
                        }
                    }
                }
            }
            SettingsCard(title: "Tab groups") {
                SettingsToggle(title: "Group related tabs", subtitle: "Apple Intelligence organizes loose tabs into named groups on this Mac.", isOn: $settings.autoGroupTabs)
                    .disabled(!AppleIntelligence.shared.isAvailable)
            }
            SettingsNote(AppleIntelligence.shared.unavailableReason ?? "Apple Intelligence runs on your Mac. Your browsing stays on this device.", systemImage: "sparkles")
        }
    }

    private var privacy: some View {
        SettingsPage(title: "Privacy", subtitle: "Manage tracking protection and website exceptions.") {
            SettingsCard(title: "Protection") {
                SettingsToggle(title: "Block ads and trackers", subtitle: "Filter unwanted requests and page elements.", isOn: $settings.blockContent)
                SettingsDivider()
                SettingsToggle(title: "Decline cookie pop-ups", subtitle: "Choose “reject all” and send Global Privacy Control. Applies to new tabs.", isOn: $settings.declineCookiePopups)
                SettingsDivider()
                SettingsToggle(title: "Clean shared links", subtitle: "Remove tracking parameters when opening and copying links.", isOn: $settings.cleanLinks)
            }
            if !settings.allowlistedHosts.isEmpty {
                SettingsCard(title: "Website exceptions", subtitle: "Ad and tracker blocking is off for these sites.") {
                    ForEach(settings.allowlistedHosts, id: \.self) { host in
                        SettingsRow(title: host) {
                            Button("Remove") { settings.setAllowlisted(host, false) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private var performance: some View {
        SettingsPage(title: "Performance", subtitle: "Balance memory use, battery life, and background tabs.") {
            SettingsCard(title: "Efficiency") {
                SettingsRow(title: "Profile", subtitle: "Set limits for optional tab unloading.") {
                    Picker("Profile", selection: $settings.profile) {
                        ForEach(EfficiencyProfile.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190)
                }
                SettingsDivider()
                SettingsToggle(title: "Automatically unload inactive tabs", subtitle: "Off by default: pages keep running with background CPU throttling. Unloading saves more memory but reloads pages when you return.", isOn: $settings.automaticallyUnloadTabs)
                SettingsDivider()
                SettingsRow(title: "Unload inactive tabs after") {
                    Stepper(value: $settings.sleepAfterMinutes, in: 0...240, step: 1) {
                        Text(settings.sleepAfterMinutes == 0 ? "Never" : "\(Int(settings.sleepAfterMinutes)) min")
                            .monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                    }.fixedSize()
                }.disabled(!settings.automaticallyUnloadTabs || settings.profile == .unlimited)
                SettingsDivider()
                SettingsRow(title: "Live tab target", subtitle: "Used only with automatic unloading. Recent tabs, edits, loading pages, media, and sign-in popups are protected.") {
                    Stepper(value: $settings.maxLiveTabs, in: 0...50) {
                        Text(settings.maxLiveTabs == 0 ? "Unlimited" : "\(settings.maxLiveTabs)")
                            .monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                    }.fixedSize()
                }.disabled(!settings.automaticallyUnloadTabs || settings.profile == .unlimited)
            }
            SettingsCard(title: "Background activity") {
                SettingsToggle(title: "Load tabs when selected", subtitle: "Background tabs wait until you open them.", isOn: $settings.lazyBackgroundTabs)
                SettingsDivider()
                SettingsToggle(title: "Battery saver", subtitle: "With automatic unloading, reclaim inactive tabs sooner on battery or in Low Power Mode.", isOn: $settings.batterySaver)
                SettingsDivider()
                SettingsRow(title: "Archive inactive tabs after") {
                    Picker("Archive inactive tabs after", selection: $settings.archiveAfterHours) {
                        Text("12 hours").tag(12.0)
                        Text("1 day").tag(24.0)
                        Text("1 week").tag(168.0)
                        Text("Never").tag(0.0)
                    }.labelsHidden().frame(width: 170)
                }
            }
            SettingsNote("Background pages keep their running state by default. Optional unloading keeps navigation history, but cannot preserve a running login or app. Recently used tabs get at least a minute before automatic unloading. Profile limits apply when unloading is enabled.", systemImage: "leaf")
        }
    }

    private var media: some View {
        SettingsPage(title: "Media & Sounds", subtitle: "Set up playback, YouTube, and sound feedback.") {
            SettingsCard(title: "Sound feedback") {
                SettingsRow(title: "Click sounds") {
                    Picker("Click sounds", selection: $settings.clickSoundScope) {
                        ForEach(ClickSoundScope.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190)
                        .accessibilityIdentifier("feather.settings.click-sounds")
                }
                SettingsDivider()
                SettingsRow(title: "Typing sounds") {
                    Picker("Typing sounds", selection: $settings.typingSoundScope) {
                        ForEach(ClickSoundScope.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190)
                        .accessibilityIdentifier("feather.settings.typing-sounds")
                }
            }
            SettingsCard(title: "Playback") {
                SettingsToggle(title: "Block autoplay", subtitle: "Require a click before media starts playing.", isOn: $settings.blockAutoplay)
                SettingsDivider()
                SettingsToggle(title: "Automatic picture in picture", subtitle: "Keep watching when you switch away from a video.", isOn: $settings.autoPictureInPicture)
            }
            SettingsCard(title: "YouTube") {
                SettingsToggle(title: "Skip sponsor segments", subtitle: "Use SponsorBlock to skip sponsored sections. Applies to new tabs.", isOn: $settings.skipSponsors)
                SettingsDivider()
                SettingsToggle(title: "Show ad-blocking popups", subtitle: "A brief notice when Feather catches an ad.", isOn: $settings.showYouTubeAdCatchPopups, identifier: "feather.settings.youtube-ad-catch-popups")
                SettingsDivider()
                SettingsRow(title: "Preferred video quality") {
                    Picker("Preferred video quality", selection: $settings.youtubeQuality) {
                        ForEach(YouTubeQuality.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 170)
                }
            }
            SettingsNote("Sound scopes apply separately to clicks and typing. “Everywhere” includes websites; tour music stays in the tour.", systemImage: "speaker.wave.2")
        }
    }
}

private struct DefaultBrowserCard: View {
    private let browser = DefaultBrowser.shared

    var body: some View {
        SettingsCard(title: "Default browser") {
            SettingsRow(title: "Open links with Feather", subtitle: browser.isDefault ? "Feather is your default web browser." : "Links currently open in \(browser.currentName ?? "another browser").") {
                if browser.isDefault {
                    Label("Default", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(SettingsTheme.accent)
                } else {
                    Button("Make Default") { browser.makeDefault() }
                }
            }
        }
        .onAppear { browser.refresh() }
    }
}
