import SwiftUI

/// Arc-style sidebar: navigation buttons, address pill, Favorites, pinned tabs,
/// tab list, and a footer with memory use and spaces.
struct SidebarView: View {
    let state: BrowserState
    let window: WindowState
    let openCommandBar: (CommandBarMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TopBar(tab: window.activeTab, state: state)
            AddressPill(tab: window.activeTab, state: state) { openCommandBar(.edit) }
            FavoritesGrid(window: window, state: state)
            if !window.space.pinned.isEmpty {
                PinnedList(space: window.space, window: window, state: state)
            }
            if !state.favorites.isEmpty || !window.space.pinned.isEmpty {
                Divider().padding(.horizontal, 6)
            }
            TabList(space: window.space, window: window, state: state) { openCommandBar(.newTab) }
            if let playing = state.media.nowPlaying(excluding: window) {
                NowPlayingBar(tab: playing, window: window, state: state)
            }
            DownloadLine(downloads: state.downloads)
            Footer(state: state, window: window)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowDragArea())
    }
}

private struct TopBar: View {
    let tab: Tab?
    let state: BrowserState

    var body: some View {
        let glass = state.settings.glassInterface
        HStack(spacing: 2) {
            Spacer()
            HStack(spacing: 2) { buttons }
                .padding(.horizontal, glass ? 6 : 0)
                .frame(height: glass ? 28 : 22)
                .featherSurface(Capsule(), glass: glass, fill: 0, interactive: true)
        }
        .frame(height: 22)
        .padding(.leading, 64)  // traffic lights
    }

    @ViewBuilder private var buttons: some View {
            if state.agentAccessEnabled {
                IconButton("terminal", help: "Agent access is on. Turn off agent access") {
                    NSApp.sendAction(#selector(AppDelegate.toggleAgentAccess(_:)), to: nil, from: nil)
                }
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("feather.agent-access")
            }
            IconButton("chevron.left", help: "Back") { tab?.webView?.goBack() }
                .disabled(!(tab?.canGoBack ?? false))
            IconButton("chevron.right", help: "Forward") { tab?.webView?.goForward() }
                .disabled(!(tab?.canGoForward ?? false))
            if tab?.isLoading == true {
                IconButton("xmark", help: "Stop") { tab?.webView?.stopLoading() }
            } else {
                IconButton("arrow.clockwise", help: "Reload") {
                    if let tab {
                        if tab.webView == nil { state.lifecycle.ensureLive(tab) } else { tab.webView?.reload() }
                    }
                }
            }
    }
}

private struct AddressPill: View {
    let tab: Tab?
    let state: BrowserState
    let open: () -> Void

    private var host: String? {
        guard let url = tab?.url, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url.host()?.replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
                    if host != nil {
                        Image(systemName: tab?.isSecure == true ? "lock.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(host ?? "Search or enter address")
                        .lineLimit(1)
                        .foregroundStyle(host == nil ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open location")
            .accessibilityValue(tab?.url?.absoluteString ?? "New Tab")
            .accessibilityIdentifier("feather.address")
            .background(TourAnchor(.address))
            readerButton
            favoriteButton
            consentIndicator
            blockingButton
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .featherSurface(RoundedRectangle(cornerRadius: state.settings.glassInterface ? 16 : 9, style: .continuous),
                        glass: state.settings.glassInterface, fill: 0.07, interactive: true)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var readerButton: some View {
        if let tab, tab.isReaderable || tab.isReaderOpen {
            Button { state.toggleReader(tab) } label: {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 11))
                    .foregroundStyle(tab.isReaderOpen ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(tab.isReaderOpen ? "Hide reader (⇧⌘R)" : "Show reader (⇧⌘R)")
            .accessibilityLabel(tab.isReaderOpen ? "Hide reader" : "Show reader")
            .accessibilityIdentifier("feather.reader")
        }
    }

    @ViewBuilder private var favoriteButton: some View {
        if let tab, host != nil {
            let favorite = tab.favoriteID != nil
            Button {
                if let existing = state.favorite(of: tab) {
                    state.removeFavorite(existing, window: state.window(showing: tab))
                } else {
                    state.addFavorite(from: tab, window: state.window(showing: tab))
                }
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(favorite ? Color.yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(favorite ? "Remove from Favorites" : "Add to Favorites (⇧⌘D)")
            .accessibilityLabel(favorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityIdentifier("feather.favorite-toggle")
            .background(TourAnchor(.favorite))
        }
    }

    @ViewBuilder private var consentIndicator: some View {
        if let cmp = tab?.declinedCookies {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Feather declined cookies on this page (\(cmp))")
        }
    }

    @ViewBuilder private var blockingButton: some View {
        if let host {
            let blocking = state.settings.blockContent && !state.settings.isAllowlisted(host)
            Button {
                state.settings.setAllowlisted(host, blocking)
                tab?.webView?.reload()
            } label: {
                Image(systemName: blocking ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(blocking ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(blocking ? "Ads and trackers blocked on \(host). Click to allow." : "Blocking is off for \(host)")
            .disabled(!state.settings.blockContent)
            .accessibilityLabel(blocking ? "Allow ads and trackers on this site" : "Block ads and trackers on this site")
            .accessibilityIdentifier("feather.content-blocking")
        }
    }
}

/// Pinned tabs, above the divider. They stay in this space until unpinned.
private struct PinnedList: View {
    let space: Space
    let window: WindowState
    let state: BrowserState

    var body: some View {
        VStack(spacing: 2) {
            ForEach(space.pinned) { tab in
                TabRow(tab: tab, selected: window.isShowing(tab), window: window, state: state)
            }
        }
    }
}

private struct TabList: View {
    let space: Space
    let window: WindowState
    let state: BrowserState
    let newTab: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button(action: newTab) {
                    Label("New Tab", systemImage: "plus")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feather.new-tab")
                .background(TourAnchor(.newTab))
                if !space.tabs.isEmpty {
                    Button { state.clearTabs(in: window) } label: {
                        Label("Clear", systemImage: "arrow.down")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Archive all unpinned tabs. Find them again with ⌘T.")
                    .accessibilityLabel("Archive unpinned tabs")
                    .accessibilityIdentifier("feather.archive-tabs")
                }
            }

            if state.grouper.organizing == space.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Organizing tabs…")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 20)
            }

            // Loose tabs first (new tabs land at the top), then the named groups.
            let sections = space.tabSections()
            let loose = sections.loose
            List {
                ForEach(loose) { tab in
                    row(tab, indented: false)
                }
                .onMove { state.moveTabs(in: space, among: loose, from: $0, to: $1) }
                ForEach(space.groups) { group in
                    let members = sections.grouped[group.id] ?? []
                    if !members.isEmpty {
                        Section {
                            GroupHeader(group: group, count: members.count, space: space, state: state)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            // A collapsed group still shows the tab you're on.
                            let shown = group.collapsed ? members.filter(window.isShowing) : members
                            ForEach(shown) { tab in
                                row(tab, indented: true)
                            }
                            .onMove { state.moveTabs(in: space, among: shown, from: $0, to: $1) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 30)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ tab: Tab, indented: Bool) -> some View {
        TabRow(tab: tab, selected: window.isShowing(tab), window: window, state: state, indented: indented)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// A group's title row: click to fold it away; right-click to rename, ungroup, or close its tabs.
private struct GroupHeader: View {
    let group: TabGroup
    let count: Int
    let space: Space
    let state: BrowserState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Image(systemName: group.automatic ? "sparkles" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(group.automatic ? AnyShapeStyle(.purple.opacity(0.8)) : AnyShapeStyle(.secondary))
            Text(group.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { state.toggleCollapsed(group) } }
        .onHover { hovering = $0 }
        .help(group.automatic ? "Grouped by Apple Intelligence. Click to fold." : "Click to fold")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(count) tabs, \(group.collapsed ? "collapsed" : "expanded")")
        .accessibilityIdentifier("feather.tab-group.\(group.id.uuidString)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.toggleCollapsed(group) }
        .contextMenu {
            Button("Rename…") {
                if let name = promptForText(title: "Rename Group", message: "", initial: group.name) {
                    state.rename(group, to: name)
                }
            }
            Button(group.collapsed ? "Expand" : "Collapse") { state.toggleCollapsed(group) }
            Divider()
            Button("Ungroup") { state.ungroup(group, in: space) }
            Button("Close \(count) \(count == 1 ? "Tab" : "Tabs")") { state.closeTabs(in: group, in: space) }
        }
    }
}

private struct TabRow: View {
    let tab: Tab
    let selected: Bool
    let window: WindowState
    let state: BrowserState
    var indented = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button { state.select(tab, in: window) } label: {
                HStack(spacing: 8) {
                    Favicon(tab: tab, size: 16)
                        .opacity(tab.isLive || selected ? 1 : 0.5)
                    Text(tab.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(tab.isLive || selected ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.displayTitle)
            .accessibilityValue(tab.url?.absoluteString ?? "New Tab")
            .accessibilityIdentifier("feather.tab.\(tab.id.uuidString)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: Text("Close tab")) { state.close(tab) }
            if tab.isPlayingAudio || tab.isMuted {
                Button { state.media.toggleMute(tab) } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.isMuted ? .tertiary : .secondary)
                .help(tab.isMuted ? "Unmute tab" : "Mute tab")
                .accessibilityLabel(tab.isMuted ? "Unmute tab" : "Mute tab")
                .accessibilityIdentifier("feather.tab.\(tab.id.uuidString).mute")
            }
            if hovering {
                Button { state.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close tab")
                .accessibilityLabel("Close tab")
                .accessibilityIdentifier("feather.tab.\(tab.id.uuidString).close")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .featherSurface(RoundedRectangle(cornerRadius: state.settings.glassInterface ? 11 : 8, style: .continuous),
                        glass: state.settings.glassInterface && selected, fill: selected ? 0.14 : hovering ? 0.06 : 0)
        .padding(.leading, indented ? 12 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tab.displayTitle + memoryNote(tab))
        .accessibilityElement(children: .contain)
        .contextMenu { TabMenu(tab: tab, window: window, state: state) }
    }
}

private func memoryNote(_ tab: Tab) -> String {
    guard tab.isLive else { return "\nSleeping: uses no memory" }
    return tab.footprint.map { "\nUsing \(MemoryMonitor.format($0))" } ?? ""
}

private struct TabMenu: View {
    let tab: Tab
    let window: WindowState
    let state: BrowserState

    var body: some View {
        let pinned = state.space(of: tab)?.isPinned(tab) ?? false
        if let favorite = state.favorite(of: tab) {
            Button("Remove from Favorites") { state.removeFavorite(favorite, window: window) }
        } else {
            Button(pinned ? "Unpin Tab" : "Pin Tab") { state.togglePin(tab) }
            if let scheme = tab.url?.scheme, scheme == "https" || scheme == "http" {
                Button("Add to Favorites") { state.addFavorite(from: tab, window: window) }
            }
        }
        if tab.isLive {
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { state.media.toggleMute(tab) }
        }
        Button("Open in Split View") { state.showInSplit(tab, in: window) }
            .disabled(window.isShowing(tab) || window.primary == nil)
        if let space = state.space(of: tab), space.tabs.contains(where: { $0 === tab }) {
            Menu("Move to Group") {
                ForEach(space.groups.filter { $0.id != tab.groupID }) { group in
                    Button(group.name) { state.move(tab, toGroup: group) }
                }
                if !space.groups.isEmpty { Divider() }
                Button("New Group…") {
                    if let name = promptForText(title: "New Group", message: "", initial: "") {
                        state.newGroup(named: name, with: [tab], in: space)
                    }
                }
                if space.group(of: tab) != nil {
                    Button("Remove from Group") { state.move(tab, toGroup: nil) }
                }
            }
        }
        if tab.isLive && !window.isShowing(tab) {
            Button("Put Tab to Sleep") { Task { await state.lifecycle.sleep(tab, reason: .idle) } }
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            let url = tab.url.map { state.settings.cleanLinks ? LinkCleaner.clean($0) : $0 }
            NSPasteboard.general.setString(url?.absoluteString ?? "", forType: .string)
        }
        if state.spaces.count > 1 && tab.favoriteID == nil {
            Menu("Move to Space") {
                ForEach(state.spaces.filter { !$0.contains(tab) }) { space in
                    Button(space.name) { state.move(tab, to: space) }
                }
            }
        }
        Divider()
        Button("Close Tab") { state.close(tab) }
    }
}

/// A tab's icon: a spinner while it loads its first content, the site's
/// favicon, or a letter tile.
struct Favicon: View {
    let tab: Tab
    let size: CGFloat

    var body: some View {
        Group {
            if tab.isLoading && tab.progress < 0.9 && tab.isLive {
                ProgressView().controlSize(.small).scaleEffect(size / 20)
            } else if let image = tab.favicon {
                Image(nsImage: image).resizable().interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else if let host = tab.url?.host(), !host.isEmpty {
                LetterTile(host: host, size: size)
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// What's playing in another tab: artwork, title, play/pause, picture-in-picture,
/// mute. Clicking the title goes to the tab.
private struct NowPlayingBar: View {
    let tab: Tab
    let window: WindowState
    let state: BrowserState
    @State private var hovering = false

    var body: some View {
        let media = tab.media
        HStack(spacing: 8) {
            Group {
                if let artwork = media?.artwork {
                    AsyncImage(url: artwork) { image in image.resizable().scaledToFill() } placeholder: { Favicon(tab: tab, size: 28) }
                } else {
                    Favicon(tab: tab, size: 20).frame(width: 28, height: 28)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Button { state.select(tab, in: window) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(media?.title.isEmpty == false ? media!.title : tab.displayTitle)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(media?.artist.isEmpty == false ? media!.artist : (tab.url?.host() ?? ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to tab")
            if media?.isVideo == true {
                control(media?.inPictureInPicture == true ? "pip.exit" : "pip.enter", "Picture in picture") {
                    state.media.togglePictureInPicture(of: tab)
                }
            }
            control(tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", tab.isMuted ? "Unmute" : "Mute") {
                state.media.toggleMute(tab)
            }
            control(media?.playing == true ? "pause.fill" : "play.fill", media?.playing == true ? "Pause" : "Play") {
                state.media.togglePlayback(of: tab)
            }
        }
        .padding(6)
        .featherSurface(RoundedRectangle(cornerRadius: state.settings.glassInterface ? 14 : 9, style: .continuous),
                        glass: state.settings.glassInterface, fill: hovering ? 0.1 : 0.06)
        .onHover { hovering = $0 }
    }

    private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The latest download; click for the downloads popover.
private struct DownloadLine: View {
    let downloads: DownloadManager
    @State private var showing = false

    var body: some View {
        if let item = downloads.active ?? downloads.items.last {
            Button { showing.toggle() } label: {
                HStack(spacing: 6) {
                    DownloadIcon(item: item)
                    Text(item.filename).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    let running = downloads.items.filter(\.isActive).count
                    if item.isActive {
                        Text(running > 1 ? "\(running) downloads" : "\(Int(item.progress * 100))%").monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Downloads")
            .accessibilityValue(item.filename)
            .accessibilityIdentifier("feather.downloads")
            .popover(isPresented: $showing, arrowEdge: .trailing) { DownloadsPopover(downloads: downloads) }
        }
    }
}

private struct DownloadIcon: View {
    let item: DownloadManager.Item

    var body: some View {
        if item.isActive {
            ProgressView(value: item.progress).progressViewStyle(.circular).controlSize(.mini)
        } else {
            Image(systemName: item.cancelled ? "xmark.circle" : item.failed ? "exclamationmark.circle" : "checkmark.circle")
        }
    }
}

private struct DownloadsPopover: View {
    let downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .disabled(!downloads.items.contains { !$0.isActive })
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(downloads.items.reversed()) { item in
                        DownloadRow(item: item, downloads: downloads)
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 340)
    }
}

private struct DownloadRow: View {
    let item: DownloadManager.Item
    let downloads: DownloadManager

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let destination = item.destination, item.finished {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: destination.path)).resizable()
                } else {
                    Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary).padding(4)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                if item.isActive {
                    ProgressView(value: item.progress).controlSize(.small)
                } else {
                    Text(item.cancelled ? "Cancelled" : item.failed ? "Failed" : "Done")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.filename)
            .accessibilityIdentifier("feather.download.\(item.id.uuidString)")
            .accessibilityActions {
                if item.finished {
                    Button("Open download") { downloads.open(item) }
                }
            }
            Spacer(minLength: 4)
            if item.isActive {
                Button { downloads.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
                    .accessibilityLabel("Cancel download \(item.filename)")
                    .accessibilityIdentifier("feather.download.\(item.id.uuidString).cancel")
            } else if item.finished {
                Button { downloads.reveal(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
                    .accessibilityLabel("Show \(item.filename) in Finder")
                    .accessibilityIdentifier("feather.download.\(item.id.uuidString).reveal")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { downloads.open(item) }
        .accessibilityElement(children: .contain)
    }
}

private struct Footer: View {
    let state: BrowserState
    let window: WindowState

    var body: some View {
        HStack(spacing: 8) {
            if state.settings.showMemoryInSidebar {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showMemoryPanel(_:)), to: nil, from: nil)
                } label: {
                    HStack(spacing: 4) {
                        if state.batterySaverActive {
                            Image(systemName: "leaf.fill").foregroundStyle(.green.opacity(0.8))
                                .help("Battery saver: background tabs sleep sooner")
                        }
                        Image(systemName: "memorychip")
                        Text(MemoryMonitor.format(state.memory.total)).monospacedDigit()
                        Text("· \(state.liveTabs.count) live").foregroundStyle(.tertiary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Memory used by Feather and its web processes")
            }
            Spacer(minLength: 0)
            SpaceBar(state: state, window: window)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, state.settings.glassInterface ? 10 : 4)
        .frame(height: state.settings.glassInterface ? 30 : nil)
        .featherSurface(Capsule(), glass: state.settings.glassInterface, fill: 0)
    }
}

private struct SpaceBar: View {
    let state: BrowserState
    let window: WindowState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(state.spaces) { space in
                let selected = window.space === space
                Button { state.switchToSpace(space, in: window) } label: {
                    Circle()
                        .fill(Color(nsColor: NSColor(hue: space.hue, saturation: 0.6, brightness: 0.85, alpha: 1)))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.primary.opacity(selected ? 0.8 : 0), lineWidth: 1.5).padding(-3))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(space.name)
                .accessibilityLabel("\(space.name) space")
                .accessibilityIdentifier("feather.space.\(space.id.uuidString)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu {
                        Button("Rename…") {
                            if let name = promptForText(title: "Rename Space", message: "", initial: space.name) {
                                space.name = name
                                state.scheduleSave()
                            }
                        }
                        Button("Delete Space…", role: .destructive) {
                            let alert = NSAlert()
                            alert.messageText = "Delete “\(space.name)”?"
                            alert.informativeText = "Its tabs, cookies, and website data will be removed."
                            alert.addButton(withTitle: "Delete")
                            alert.addButton(withTitle: "Cancel")
                            if alert.runModal() == .alertFirstButtonReturn { state.deleteSpace(space) }
                        }
                        .disabled(state.spaces.count < 2)
                    }
            }
            Button {
                NSApp.sendAction(#selector(BrowserWindowController.newSpace(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("New Space")
            .accessibilityLabel("New Space")
            .accessibilityIdentifier("feather.new-space")
            .background(TourAnchor(.spaces))
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("feather.navigation.\(help.lowercased())")
    }
}

/// Lets empty sidebar space drag the window, like a title bar.
private struct WindowDragArea: View {
    var body: some View {
        Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
    }
}
