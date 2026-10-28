import AppKit
import SwiftUI
import WebKit

/// Fills saved logins and offers to save new ones, driven by `LoginFormScript`.
/// A frame only ever sees logins for its own site, using the origin WebKit
/// reports for the message, and plain-HTTP pages never get HTTPS logins.
final class PasswordController {
    static let shared = PasswordController()

    weak var state: BrowserState?
    private let store = PasswordStore.shared
    private var popover: NSPopover?
    private var saveQuestion: UUID?

    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView else { return }
        let frame = message.frameInfo
        switch type {
        case "focus":
            let rect = (body["rect"] as? [Double]) ?? []
            showSuggestions(in: webView, frame: frame, isNewPassword: body["isNew"] as? Bool ?? false,
                            fieldRect: rect.count == 4 && body["isTopFrame"] as? Bool == true ? rect : nil)
        case "typing":
            closePopover()
        case "credentials":
            guard let password = body["password"] as? String, !password.isEmpty else { return }
            offerToSave(username: body["username"] as? String ?? "", password: password, frame: frame, webView: webView)
        default:
            break
        }
    }

    // MARK: Filling

    private func showSuggestions(in webView: WKWebView, frame: WKFrameInfo, isNewPassword: Bool, fieldRect: [Double]?) {
        let origin = frame.securityOrigin
        let secure = origin.protocol == "https"
        let logins = store.logins(forHost: origin.host).filter { secure || !$0.isHTTPS }
        guard !logins.isEmpty || isNewPassword else { return closePopover() }

        let view = PasswordPopoverView(
            host: origin.host, logins: logins, offersStrongPassword: isNewPassword,
            choose: { [weak self, weak webView] login in
                self?.closePopover()
                if let webView { self?.fill(login, in: webView, frame: frame) }
            },
            suggest: { [weak self, weak webView] in
                self?.closePopover()
                if let webView { self?.fillStrongPassword(in: webView, frame: frame) }
            },
            manage: { [weak self] in
                self?.closePopover()
                NSApp.sendAction(#selector(AppDelegate.showPasswordsSettings(_:)), to: nil, from: nil)
            })

        closePopover()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: anchor(for: fieldRect, in: webView), of: webView,
                     preferredEdge: webView.isFlipped ? .maxY : .minY)
        self.popover = popover
        // Keep typing in the page.
        webView.window?.makeFirstResponder(webView)
    }

    /// The field's rect in the web view; for subframes, whose offset isn't known, the pointer.
    private func anchor(for fieldRect: [Double]?, in webView: WKWebView) -> NSRect {
        guard let fieldRect else {
            let point = webView.convert(webView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            return NSRect(x: point.x, y: point.y, width: 1, height: 1)
        }
        let scale = webView.pageZoom * webView.magnification
        let rect = NSRect(x: fieldRect[0] * scale, y: fieldRect[1] * scale,
                          width: max(fieldRect[2] * scale, 1), height: max(fieldRect[3] * scale, 1))
        return webView.isFlipped ? rect : NSRect(x: rect.minX, y: webView.bounds.height - rect.maxY,
                                                 width: rect.width, height: rect.height)
    }

    func closePopover() {
        popover?.close()
        popover = nil
    }

    private func fill(_ login: SavedLogin, in webView: WKWebView, frame: WKFrameInfo) {
        // A requested fill is an active login flow, including while Touch ID waits.
        state?.tab(showing: webView)?.hasUnsavedInput = true
        Task {
            guard await PasswordUnlock.shared.unlock(reason: "fill your password for \(login.host)"),
                  let password = store.password(for: login) else { return }
            let filled = (try? await webView.callAsyncJavaScript("const filled = __featherFill(username, password); if (filled) globalThis.__featherProtectInput?.(); return filled;",
                                                       arguments: ["username": login.username, "password": password],
                                                       in: frame, contentWorld: .defaultClient)) as? Bool
            // Our own fill dispatches synthetic input events, so the trusted-edit
            // tracker deliberately ignores them. Protect the successful fill here.
            if filled == true { state?.tab(showing: webView)?.hasUnsavedInput = true }
        }
    }

    private func fillStrongPassword(in webView: WKWebView, frame: WKFrameInfo) {
        state?.tab(showing: webView)?.hasUnsavedInput = true
        let password = StrongPassword.generate()
        Task {
            let filled = (try? await webView.callAsyncJavaScript("const filled = __featherFillNewPassword(password); if (filled) globalThis.__featherProtectInput?.(); return filled;",
                                                                 arguments: ["password": password],
                                                                 in: frame, contentWorld: .defaultClient)) as? Bool
            if filled == true {
                state?.tab(showing: webView)?.hasUnsavedInput = true
                state?.toasts.show("Strong password filled. Feather will offer to save it when you continue.",
                                   symbol: "key.fill", in: windowID(for: webView))
            }
        }
    }

    // MARK: Saving

    private func offerToSave(username: String, password: String, frame: WKFrameInfo, webView: WKWebView) {
        guard let state else { return }
        let host = frame.securityOrigin.host.lowercased()
        let secure = frame.securityOrigin.protocol == "https"
        guard !host.isEmpty, !state.settings.neverSavesPasswords(for: host) else { return }
        let existing = store.login(host: host, username: username)
        if let existing, store.password(for: existing) == password { return }

        let who = username.isEmpty ? host : "\(username) on \(host)"
        let message = existing == nil ? "Save password for \(who)?" : "Update the saved password for \(who)?"
        if let saveQuestion { state.toasts.dismiss(saveQuestion) }
        saveQuestion = state.toasts.show(message, symbol: "key.fill", in: windowID(for: webView), actions: [
            .init(title: "Never for This Site") { [weak state] in state?.settings.setNeverSavePasswords(for: host) },
            .init(title: existing == nil ? "Save" : "Update", isPrimary: true) { [weak self, weak state] in
                guard let self else { return }
                if self.store.save(host: host, username: username, password: password, isHTTPS: secure) {
                    state?.toasts.show("Password saved for \(host)", symbol: "key.fill")
                } else {
                    state?.toasts.show("Couldn't save the password to the Keychain", symbol: "exclamationmark.triangle.fill")
                }
            },
        ])
    }

    private func windowID(for webView: WKWebView) -> UUID? {
        guard let state else { return nil }
        if let tab = state.tab(showing: webView), let window = state.window(showing: tab) { return window.id }
        return state.keyWindow?.id
    }
}

struct PasswordPopoverView: View {
    let host: String
    let logins: [SavedLogin]
    let offersStrongPassword: Bool
    let choose: (SavedLogin) -> Void
    let suggest: () -> Void
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(logins) { login in
                Row(symbol: "key.fill", title: login.username.isEmpty ? "No username" : login.username,
                    subtitle: login.host == host ? nil : login.host) { choose(login) }
            }
            if offersStrongPassword {
                Row(symbol: "wand.and.stars", title: "Suggest Strong Password", subtitle: nil, action: suggest)
            }
            Divider().padding(.vertical, 2)
            Row(symbol: "lock.rectangle.stack", title: "Feather Passwords…", subtitle: nil, action: manage)
        }
        .padding(6)
        .frame(width: 280)
    }

    private struct Row: View {
        let symbol: String
        let title: String
        let subtitle: String?
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}
