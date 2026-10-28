import SwiftUI
import UniformTypeIdentifiers

/// Settings → Passwords: Feather's saved logins, CSV import, never-save sites, and passkey status.
struct PasswordsSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var logins: [SavedLogin] = []
    @State private var search = ""
    @State private var revealed: [String: String] = [:]
    private let store = PasswordStore.shared

    private var filtered: [SavedLogin] {
        let needle = search.lowercased()
        return needle.isEmpty ? logins : logins.filter { $0.host.contains(needle) || $0.username.lowercased().contains(needle) }
    }

    var body: some View {
        SettingsPage(title: "Passwords", subtitle: "Find and manage your saved logins.") {
            SettingsCard {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search websites or usernames", text: $search)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search passwords")
                            .accessibilityIdentifier("feather.settings.passwords.search")
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(SettingsTheme.border, lineWidth: 1))

                    Button("Import…", action: importCSV)
                        .controlSize(.large)
                        .help("Import a CSV exported from Passwords, Safari, Chrome, Firefox, or Bitwarden")
                        .accessibilityIdentifier("feather.settings.passwords.import")
                }
                .padding(16)
            }

            SettingsSectionHeader("Saved passwords", detail: logins.isEmpty ? nil : "\(logins.count)")
            SettingsCard {
                if logins.isEmpty {
                    passwordEmptyState(title: "No saved passwords yet", subtitle: "Feather offers to save your login when you sign in. You can also import a passwords CSV.", symbol: "key")
                } else if filtered.isEmpty {
                    passwordEmptyState(title: "No matching passwords", subtitle: "Try a different website or username.", symbol: "magnifyingglass")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, login in
                            passwordRow(login)
                            if index < filtered.count - 1 {
                                Divider().overlay(SettingsTheme.border).padding(.leading, 60)
                            }
                        }
                    }
                }
            }

            if !settings.neverSavePasswordSites.isEmpty {
                SettingsCard {
                    DisclosureGroup {
                        VStack(spacing: 0) {
                            ForEach(settings.neverSavePasswordSites, id: \.self) { site in
                                HStack(spacing: 12) {
                                    Text(site).font(.system(size: 13))
                                    Spacer()
                                    Button("Remove") { settings.setNeverSavePasswords(for: site, false) }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Allow saving passwords on \(site)")
                                }
                                .padding(.vertical, 9)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack {
                            Text("Never-save sites").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(settings.neverSavePasswordSites.count)")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }

            PasskeyStatus()
        }
        .onAppear(perform: reload)
    }

    private func passwordEmptyState(title: String, subtitle: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(SettingsTheme.accent)
                .frame(width: 44, height: 44)
                .background(SettingsTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func passwordRow(_ login: SavedLogin) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FaviconImage(host: login.host, size: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(login.host).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(login.username.isEmpty ? "No username" : login.username)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 14) {
                    Button(revealed[login.id] == nil ? "Show" : "Hide") { toggleReveal(login) }
                        .foregroundStyle(SettingsTheme.accent)
                        .accessibilityLabel("\(revealed[login.id] == nil ? "Show" : "Hide") password for \(login.host)")
                        .accessibilityIdentifier(actionIdentifier("reveal", login: login))
                    Button { copy(login) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy password")
                        .accessibilityLabel("Copy password for \(login.host)")
                        .accessibilityIdentifier(actionIdentifier("copy", login: login))
                    Button(role: .destructive) { delete(login) } label: { Image(systemName: "trash") }
                        .help("Delete password")
                        .accessibilityLabel("Delete password for \(login.host)")
                        .accessibilityIdentifier(actionIdentifier("delete", login: login))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if let password = revealed[login.id] {
                Text(password)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SettingsTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 40)
            }
        }
        .padding(16)
    }

    private func actionIdentifier(_ action: String, login: SavedLogin) -> String {
        let identifier = login.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login.host
        return "feather.settings.passwords.\(action).\(identifier)"
    }

    private func reload() {
        logins = store.allLogins()
    }

    private func toggleReveal(_ login: SavedLogin) {
        if revealed[login.id] != nil {
            revealed[login.id] = nil
            return
        }
        Task {
            guard await PasswordUnlock.shared.unlock(reason: "show your password for \(login.host)") else { return }
            revealed[login.id] = store.password(for: login)
        }
    }

    private func copy(_ login: SavedLogin) {
        Task {
            guard await PasswordUnlock.shared.unlock(reason: "copy your password for \(login.host)"),
                  let password = store.password(for: login) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(password, forType: .string)
            // Clear it again after 90 s unless something else was copied since.
            let count = pasteboard.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                if pasteboard.changeCount == count { pasteboard.clearContents() }
            }
        }
    }

    private func delete(_ login: SavedLogin) {
        let alert = NSAlert()
        alert.messageText = "Delete the password for \(login.username.isEmpty ? login.host : login.username + " on " + login.host)?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.delete(login)
        revealed[login.id] = nil
        reload()
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a passwords CSV exported from Passwords, Safari, Chrome, Firefox, or Bitwarden."
        guard panel.runModal() == .OK, let url = panel.url,
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        else { return }
        let result = PasswordCSV.entries(from: text)
        let saved = result.entries.filter { entry in
            store.save(host: entry.host, username: entry.username, password: entry.password,
                       isHTTPS: !entry.url.lowercased().hasPrefix("http://"))
        }.count
        reload()

        let alert = NSAlert()
        alert.messageText = result.entries.isEmpty ? "No passwords found in that file" : "Imported \(saved) password(s)"
        var details = result.skipped > 0 ? "\(result.skipped) row(s) without a website or password were skipped. " : ""
        details += "The file you imported contains your passwords in plain text."
        alert.informativeText = details
        alert.addButton(withTitle: "Move File to Trash")
        alert.addButton(withTitle: "Keep File")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.recycle([url]) }
    }
}

private struct PasskeyStatus: View {
    var body: some View {
        let (symbol, text): (String, String) = switch Passkeys.status {
        case .needsEntitlement:
            ("person.badge.key", "Passkeys aren’t available in this build. You can still sign in with a password.")
        case .notDetermined: ("person.badge.key", "Feather will ask for permission when you first use a passkey.")
        case .allowed: ("person.badge.key.fill", "Passkeys are available from this Mac, your phone, and security keys.")
        case .denied: ("exclamationmark.triangle", "Passkeys are turned off for Feather in System Settings → Privacy & Security.")
        }
        SettingsNote(text, systemImage: symbol)
    }
}

struct FaviconImage: View {
    let host: String
    var size: CGFloat = 16
    @State private var loadedHost: String?
    @State private var loadedImage: NSImage?

    var body: some View {
        Group {
            if let image = Favicons.shared.cached(host: host) ?? Favicons.shared.cached(host: "www." + host)
                ?? (loadedHost == host ? loadedImage : nil) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                LetterTile(host: host, size: size)
            }
        }
        .task(id: host) {
            var image = await Favicons.shared.loadCached(host: host)
            if image == nil { image = await Favicons.shared.loadCached(host: "www." + host) }
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedHost = host
        }
    }
}

/// Stand-in icon: the site's first letter on a color derived from its host.
struct LetterTile: View {
    let host: String
    let size: CGFloat

    var body: some View {
        let name = Autocomplete.stripWWW(host)
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color(hue: hue, saturation: 0.45, brightness: 0.75))
            .frame(width: size, height: size)
            .overlay(Text(name.first.map { String($0).uppercased() } ?? "•")
                .font(.system(size: size * 0.62, weight: .semibold)).foregroundStyle(.white))
    }
}
