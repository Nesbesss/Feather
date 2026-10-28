import SwiftUI
import UniformTypeIdentifiers

/// Arc-style Favorites: large icon tiles at the top of the sidebar, the same in
/// every space. Click opens the site (or goes back to its saved page), drag to
/// reorder, drop a link to add one. Until there are four, dashed tiles suggest
/// your most visited sites.
struct FavoritesGrid: View {
    let window: WindowState
    let state: BrowserState
    @State private var suggestions: [FavoriteSuggestions.Site] = []

    private static let suggestUntil = 4

    var body: some View {
        let suggesting = !state.settings.hideFavoriteSuggestions && state.favorites.count < Self.suggestUntil
        if !state.favorites.isEmpty || suggesting {
            VStack(alignment: .leading, spacing: 6) {
                if state.favorites.isEmpty {
                    HStack {
                        Text("Add your everyday sites")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { state.settings.hideFavoriteSuggestions = true } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Hide suggestions (turn them back on in Settings)")
                        .accessibilityLabel("Hide suggestions")
                    }
                    .padding(.horizontal, 4)
                }
                GlassEffectContainer(spacing: 6) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                        ForEach(state.favorites) { favorite in
                            FavoriteTile(favorite: favorite, window: window, state: state)
                        }
                        if suggesting {
                            ForEach(suggestions.prefix(Self.suggestUntil - state.favorites.count), id: \.host) { site in
                                SuggestedTile(site: site, state: state)
                            }
                        }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let web = urls.filter { $0.scheme == "https" || $0.scheme == "http" }
                    web.forEach { state.addFavorite(url: $0, title: "") }
                    return !web.isEmpty
                }
            }
            .task(id: state.favorites.count) { suggestions = state.favoriteSuggestions() }
        }
    }
}

/// A dashed tile for a suggested site; one click adds it to Favorites.
private struct SuggestedTile: View {
    let site: FavoriteSuggestions.Site
    let state: BrowserState
    @State private var hovering = false

    var body: some View {
        Button { state.addFavorite(url: site.url, title: "") } label: {
            FaviconImage(host: site.host, size: 18)
                .opacity(hovering ? 1 : 0.6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .background(RoundedRectangle(cornerRadius: state.settings.glassInterface ? 14 : 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(hovering ? 0.8 : 0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add \(site.host) to Favorites")
        .accessibilityLabel("Add \(site.host) to Favorites")
        .contextMenu {
            Button("Add to Favorites") { state.addFavorite(url: site.url, title: "") }
            Button("Hide Suggestions") { state.settings.hideFavoriteSuggestions = true }
        }
    }
}

private struct FavoriteTile: View {
    let favorite: Favorite
    let window: WindowState
    let state: BrowserState
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let glass = state.settings.glassInterface
        let tab = window.space.tab(for: favorite)
        let selected = tab.map(window.isShowing) ?? false
        let wandered = tab.map { !favorite.isAtSavedPage($0.url) } ?? false
        Button { state.open(favorite, in: window) } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let tab {
                        Favicon(tab: tab, size: 20)
                    } else {
                        FaviconImage(host: favorite.url.host() ?? favorite.host, size: 20)
                    }
                }
                .opacity(tab?.isLive == true || selected ? 1 : 0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
                if wandered {
                    Circle().fill(.secondary).frame(width: 5, height: 5).padding(6)
                }
                if tab?.isPlayingAudio == true || tab?.isMuted == true {
                    Image(systemName: tab?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .featherSurface(RoundedRectangle(cornerRadius: glass ? 14 : 10, style: .continuous), glass: glass,
                            fill: selected ? 0.16 : hovering || targeted ? 0.1 : 0.06,
                            tint: selected ? Color.accentColor.opacity(0.3) : nil, interactive: true)
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: glass ? 14 : 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help(tab: tab, wandered: wandered))
        .accessibilityLabel(favorite.displayTitle)
        .accessibilityValue(favorite.url.absoluteString)
        .accessibilityIdentifier("feather.favorite.\(favorite.id.uuidString)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(wandered ? "Goes back to \(favorite.host)" : "Opens \(favorite.host)")
        .contextMenu { FavoriteMenu(favorite: favorite, tab: tab, wandered: wandered, window: window, state: state) }
        .draggable(favorite.id.uuidString) {
            FaviconImage(host: favorite.url.host() ?? favorite.host, size: 24)
        }
        .dropDestination(for: String.self) { items, _ in
            for item in items {
                if let id = UUID(uuidString: item), let moved = state.favorites.first(where: { $0.id == id }) {
                    state.moveFavorite(moved, before: favorite)
                } else if let url = URL(string: item), url.scheme == "https" || url.scheme == "http" {
                    state.addFavorite(url: url, title: "")
                    if let added = state.favorites.last { state.moveFavorite(added, before: favorite) }
                }
            }
            return !items.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private func help(tab: Tab?, wandered: Bool) -> String {
        var lines = [favorite.displayTitle, favorite.host]
        if wandered, let host = tab?.url?.host() {
            lines.append("Now on \(Autocomplete.stripWWW(host)). Click again to go back.")
        }
        if let tab, !tab.isLive { lines.append("Sleeping: uses no memory") }
        if tab == nil { lines.append("Not open in this space") }
        return lines.joined(separator: "\n")
    }
}

private struct FavoriteMenu: View {
    let favorite: Favorite
    let tab: Tab?
    let wandered: Bool
    let window: WindowState
    let state: BrowserState

    var body: some View {
        if tab == nil || wandered {
            Button("Go to Saved Page") { state.goToSavedPage(of: favorite, in: window) }
        }
        if let tab, wandered {
            Button("Save Current Page as Favorite") { state.setSavedPage(of: favorite, to: tab) }
        }
        if let tab {
            Button("Open in Split View") { state.showInSplit(tab, in: window) }
                .disabled(window.isShowing(tab) || window.primary == nil)
        }
        Button("Rename…") {
            if let name = promptForText(title: "Rename Favorite", message: favorite.host, initial: favorite.displayTitle) {
                favorite.title = name
                state.scheduleSave()
            }
        }
        Button("Edit Address…") {
            guard let text = promptForText(title: "Edit Favorite", message: "The page this favorite opens.",
                                           initial: favorite.url.absoluteString),
                  case .url(let url, _)? = URLInput.resolve(text) else { return }
            favorite.url = url
            state.scheduleSave()
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(favorite.url.absoluteString, forType: .string)
        }
        Divider()
        if let tab {
            Button("Close Tab") { state.close(tab) }
        }
        Button("Remove from Favorites") { state.removeFavorite(favorite, window: window) }
    }
}
