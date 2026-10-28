import AppKit
import SwiftUI
import Observation

/// Owned by the Settings window so drafts and ongoing work survive category changes.
@Observable
final class ExtensionSettingsState {
    var storeLink = ""
    var operation: String?
    var notice: String?
}

struct ExtensionsSettingsView: View {
    @Bindable var store: WebExtensionStore
    @Bindable var state: ExtensionSettingsState
    @State private var presentations: [String: ExtensionSettingsPresentation] = [:]

    init(store: WebExtensionStore, state: ExtensionSettingsState? = nil) {
        self.store = store
        self.state = state ?? ExtensionSettingsState()
    }

    private var busy: Bool { state.operation != nil }
    private var enabledCount: Int { store.entries.filter(\.enabled).count }

    var body: some View {
        ScrollViewReader { proxy in
            SettingsPage(title: "Extensions", subtitle: "Manage your extensions and their website access.") {
                    if let error = store.lastError {
                        messageBanner(error: error)
                    }
                    if let message = state.notice {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(SettingsTheme.accent)
                            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            Button { state.notice = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Dismiss installation message")
                        }
                        .padding(16)
                        .background(SettingsTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            SettingsSectionHeader("Installed", detail: "\(enabledCount) of \(store.entries.count) enabled")
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    proxy.scrollTo("feather.extensions.add", anchor: .top)
                                }
                            } label: {
                                Label("Add Extension", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                            .accessibilityIdentifier("feather.extensions.add-button")
                        }
                        if store.entries.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.entries) { entry in
                                extensionCard(entry, presentation: presentations[entry.id] ?? .empty)
                            }
                        }
                        if !store.entries.isEmpty {
                            SettingsNote("Open extensions from the Extensions menu while viewing a page. Reload open pages after changing which extensions are enabled.")
                        }
                    }

                    addExtensionCard.id("feather.extensions.add")

                    DisclosureGroup {
                        Text("Feather supports compatible Chrome extensions through WebKit. Chrome account sync, native messaging, local-file access, and automatic updates aren't available. Some extensions may need Chrome APIs that Feather doesn't support.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    } label: {
                        Label("About compatibility", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                }
            .task(id: store.revision) { refreshPresentations() }
        }
    }

    private var emptyState: some View {
        SettingsCard {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(SettingsTheme.accent)
                    .padding(14)
                    .background(SettingsTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                Text("No extensions installed").font(.headline)
                Text("Add one from the Chrome Web Store, or import a package.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .padding(.horizontal, 20)
        }
    }

    private func extensionCard(_ entry: InstalledWebExtension, presentation: ExtensionSettingsPresentation) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    extensionIcon(presentation.icon)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .font(.system(size: 14, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Version \(entry.version)\(entry.bundled ? " · Included with Feather" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Text(entry.enabled ? "Enabled" : "Off")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(entry.enabled ? SettingsTheme.accent : .secondary)
                        Toggle("Enable \(entry.name)", isOn: Binding(get: { entry.enabled }, set: { toggle($0, entry: entry) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .tint(SettingsTheme.accent)
                            .disabled(busy)
                            .accessibilityIdentifier("feather.extensions.enabled.\(entry.id)")
                    }
                }
                HStack(spacing: 8) {
                    Button("Open") { send(#selector(AppDelegate.openExtension(_:)), id: entry.id) }
                        .buttonStyle(.bordered)
                        .disabled(!entry.enabled || busy)
                        .accessibilityIdentifier("feather.extensions.open.\(entry.id)")
                    if presentation.hasOptions {
                        Button("Options…") { send(#selector(AppDelegate.showExtensionOptions(_:)), id: entry.id) }
                            .buttonStyle(.bordered)
                            .disabled(!entry.enabled || busy)
                            .accessibilityIdentifier("feather.extensions.options.\(entry.id)")
                    }
                    Spacer()
                    Menu {
                        Button("Remove Extension…", role: .destructive) { remove(entry) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 24, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(busy)
                    .accessibilityLabel("More options for \(entry.name)")
                    .accessibilityIdentifier("feather.extensions.more.\(entry.id)")
                }
                .controlSize(.small)
            }
            .padding(18)

            Divider().overlay(SettingsTheme.border.opacity(0.3))
            DisclosureGroup {
                accessDetails(presentation)
                    .padding(.top, 12)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "hand.raised").font(.caption)
                    Text("Requested access")
                    Spacer()
                    Text(presentation.accessSummary).font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
    }

    @ViewBuilder
    private func extensionIcon(_ icon: NSImage?) -> some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit().padding(6)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(SettingsTheme.accent)
            }
        }
        .frame(width: 44, height: 44)
        .background(SettingsTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func accessDetails(_ presentation: ExtensionSettingsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !presentation.websites.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Websites").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(presentation.websiteNames, id: \.self) { website in
                        Text(website)
                            .font(.callout)
                            .textSelection(.enabled)
                            .help(presentation.websites.filter { ExtensionSettingsPresentation.websiteLabel($0) == website }.joined(separator: "\n"))
                    }
                }
            }
            if !presentation.permissions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Browser features").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(presentation.permissions, id: \.self) { permission in
                        Text(ExtensionSettingsPresentation.permissionLabel(permission))
                            .font(.callout)
                            .help(permission)
                    }
                }
            }
            if presentation.websites.isEmpty && presentation.permissions.isEmpty {
                Text("No additional website or browser access requested.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Extension settings and data stay separate in each Space.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addExtensionCard: some View {
        SettingsCard(title: "Add an extension", subtitle: "Paste a Chrome Web Store link, or import a download.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("Chrome Web Store link or extension ID", text: $state.storeLink)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .disabled(busy)
                        .accessibilityIdentifier("feather.extensions.store-link")
                        .onSubmit { installLink() }
                    Button("Install") { installLink() }
                        .buttonStyle(.borderedProminent)
                        .tint(SettingsTheme.accent)
                        .controlSize(.large)
                        .disabled(busy || state.storeLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("feather.extensions.install-link")
                }
                HStack(spacing: 10) {
                    Button { importFile() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                        .accessibilityIdentifier("feather.extensions.import")
                    Text("CRX, ZIP, or an unpacked folder")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if let progress = state.operation {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("New extensions are disabled until you review their access and turn them on.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
    }

    private func messageBanner(error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange).font(.system(size: 17))
            VStack(alignment: .leading, spacing: 8) {
                Text("An extension needs attention").font(.callout.weight(.medium))
                DisclosureGroup("Show details") {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { store.lastError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss extension message")
        }
        .padding(16)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.15)))
    }

    private func refreshPresentations() {
        presentations = Dictionary(uniqueKeysWithValues: store.entries.map { entry in
            (entry.id, ExtensionSettingsPresentation(entry: entry, resourceURL: store.resourceURL(for: entry)))
        })
    }

    private func accessDescription(_ entry: InstalledWebExtension) -> String {
        let presentation = presentations[entry.id] ?? ExtensionSettingsPresentation(entry: entry, resourceURL: store.resourceURL(for: entry))
        let access = presentation.websites + presentation.permissions
        return access.isEmpty ? "No additional website or API permissions requested." : access.sorted().joined(separator: "\n")
    }

    private func toggle(_ enabled: Bool, entry: InstalledWebExtension) {
        if enabled {
            let alert = NSAlert()
            alert.messageText = "Enable \(entry.name)?"
            alert.informativeText = "This extension requests the following access in your Feather Spaces:\n\n" + accessDescription(entry)
            alert.addButton(withTitle: "Enable Extension")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try store.setEnabled(enabled, id: entry.id) }
        catch { store.lastError = error.localizedDescription }
    }

    private func send(_ selector: Selector, id: String) {
        NSApp.sendAction(selector, to: nil, from: id as NSString)
    }

    private func installLink() {
        guard !busy else { return }
        let link = state.storeLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        state.operation = "Installing extension…"
        state.notice = nil
        Task { @MainActor in
            defer { state.operation = nil }
            do {
                let entry = try await store.installFromChromeWebStore(link)
                state.notice = "\(entry.name) is installed. Review its access, then turn it on above."
                state.storeLink = ""
            } catch { store.lastError = error.localizedDescription }
        }
    }

    private func importFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Browser Extension"
        panel.message = "Choose a Chrome .crx or .zip package, or a folder containing manifest.json."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.operation = "Importing extension…"
        state.notice = nil
        Task { @MainActor in
            defer { state.operation = nil }
            do {
                let entry = try await store.install(from: url)
                state.notice = "\(entry.name) is installed. Review its access, then turn it on above."
            } catch { store.lastError = error.localizedDescription }
        }
    }

    private func remove(_ entry: InstalledWebExtension) {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(entry.name)?"
        alert.informativeText = "This removes the extension and its saved extension data."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.operation = "Removing extension…"
        Task { @MainActor in
            defer { state.operation = nil }
            do { try await store.remove(id: entry.id) }
            catch { store.lastError = error.localizedDescription }
        }
    }
}

private struct ExtensionSettingsPresentation {
    var icon: NSImage?
    var hasOptions = false
    var websites: [String] = []
    var permissions: [String] = []
    static var empty: Self { Self() }

    private init() {}

    init(entry: InstalledWebExtension, resourceURL: URL) {
        guard let data = try? Data(contentsOf: resourceURL.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        hasOptions = manifest["options_page"] != nil || manifest["options_ui"] != nil
        var allPermissions = manifest["permissions"] as? [String] ?? []
        allPermissions += manifest["host_permissions"] as? [String] ?? []
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            allPermissions += script["matches"] as? [String] ?? []
        }
        let unique = Set(allPermissions)
        websites = unique.filter { $0 == "<all_urls>" || $0.contains("://") }.sorted()
        permissions = unique.filter { $0 != "<all_urls>" && !$0.contains("://") }.sorted()
        if let icons = manifest["icons"] as? [String: String] {
            let sizes = icons.keys.compactMap(Int.init).sorted()
            let size = sizes.last(where: { $0 <= 128 }) ?? sizes.last
            if let size, let path = icons[String(size)] {
                let root = resourceURL.standardizedFileURL
                let imageURL = root.appendingPathComponent(path).standardizedFileURL
                if imageURL.path.hasPrefix(root.path + "/") { icon = NSImage(contentsOf: imageURL) }
            }
        }
    }

    var accessSummary: String {
        if websites.contains("<all_urls>") || websites.contains("*://*/*") { return "All websites" }
        if websites.isEmpty { return permissions.isEmpty ? "None" : "Browser features" }
        return "\(websiteNames.count) \(websiteNames.count == 1 ? "website" : "websites")"
    }

    var websiteNames: [String] { Array(Set(websites.map(Self.websiteLabel))).sorted() }

    nonisolated static func websiteLabel(_ pattern: String) -> String {
        if pattern == "<all_urls>" || pattern == "*://*/*" { return "All websites" }
        if pattern.hasPrefix("file://") { return "Local files" }
        // Keep exact path restrictions available on hover and in the enable prompt.
        guard let separator = pattern.range(of: "://") else { return pattern }
        let host = pattern[separator.upperBound...].split(separator: "/").first.map(String.init) ?? pattern
        return host.hasPrefix("*.") ? String(host.dropFirst(2)) + " and subdomains" : host
    }

    nonisolated static func permissionLabel(_ permission: String) -> String {
        switch permission {
        case "storage": "Store extension data"
        case "webRequest": "Observe requests on allowed websites"
        case "webRequestBlocking": "Modify requests on allowed websites"
        case "tabs": "Read browser tabs"
        case "activeTab": "Access the current tab when opened"
        case "scripting": "Run scripts on allowed websites"
        case "cookies": "Read and change cookies on allowed websites"
        case "downloads": "Manage downloads"
        case "notifications": "Show notifications"
        case "clipboardRead": "Read the clipboard"
        case "clipboardWrite": "Write to the clipboard"
        case "history": "Read and change browsing history"
        case "bookmarks": "Manage bookmarks"
        case "alarms": "Schedule background tasks"
        case "contextMenus", "menus": "Add items to page menus"
        case "unlimitedStorage": "Store additional extension data"
        default: permission
        }
    }
}
