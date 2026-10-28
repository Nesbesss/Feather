import AppKit
import Observation
import WebKit

/// One WebKit extension controller per Space, with any number of installed
/// extensions. The controller is attached before a WKWebView is constructed.
final class BrowserExtensionManager {
    weak var state: BrowserState?
    let store: WebExtensionStore
    private var profiles: [UUID: BrowserExtensionProfile] = [:]
    private var knownIDs: Set<String>

    init(store: WebExtensionStore? = nil) {
        self.store = store ?? .shared
        knownIDs = Set(self.store.entries.map(\.id))
        observeRegistry()
    }

    private func observeRegistry() {
        withObservationTracking { _ = store.revision } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentIDs = Set(self.store.entries.map(\.id))
                let removedIDs = self.knownIDs.subtracting(currentIDs)
                self.knownIDs = currentIDs
                self.profiles.values.forEach { $0.synchronize() }
                self.observeRegistry()
                if !removedIDs.isEmpty {
                    for space in self.state?.spaces ?? [] {
                        self.clearOptionalGrants(spaceID: space.id, extensionIDs: removedIDs)
                        guard self.profiles[space.id] == nil else { continue }
                        let controller = WKWebExtensionController(configuration: .init(identifier: space.id))
                        let types = WKWebExtensionController.allExtensionDataTypes
                        let records = await controller.dataRecords(ofTypes: types)
                        await controller.removeData(ofTypes: types, from: records.filter { removedIDs.contains($0.uniqueIdentifier) })
                    }
                }
            }
        }
    }

    func controller(for space: Space, dataStore: WKWebsiteDataStore, ephemeral: Bool) -> WKWebExtensionController {
        profile(for: space, dataStore: dataStore, ephemeral: ephemeral).controller
    }

    private func profile(for space: Space, dataStore: WKWebsiteDataStore, ephemeral: Bool) -> BrowserExtensionProfile {
        if let profile = profiles[space.id] { return profile }
        let profile = BrowserExtensionProfile(space: space, state: state, store: store, dataStore: dataStore, ephemeral: ephemeral)
        profiles[space.id] = profile
        profile.synchronize()
        return profile
    }

    private func profile(for view: WKWebView) -> BrowserExtensionProfile? {
        profiles.values.first { $0.controller === view.configuration.webExtensionController }
    }

    func track(_ view: WKWebView, in space: Space) { profiles[space.id]?.track(view) }
    func bind(_ view: WKWebView, to tab: Tab, in space: Space) { profiles[space.id]?.bind(view, to: tab) }
    func untrack(_ view: WKWebView) { profile(for: view)?.untrack(view) }
    func prepare(in view: WKWebView) async {
        guard let profile = profile(for: view) else { return }
        profile.synchronize()
        await profile.ready()
    }

    func didClose(_ tab: Tab, in space: Space) { profiles[space.id]?.didClose(tab) }
    func didOpen(_ tab: Tab, in space: Space) { profiles[space.id]?.didOpen(tab) }
    func didSelect(_ tab: Tab, in space: Space) { profiles[space.id]?.didSelect(tab) }
    func didChange(_ tab: Tab, properties: WKWebExtension.TabChangedProperties) {
        guard let space = state?.space(of: tab) else { return }
        profiles[space.id]?.didChange(tab, properties: properties)
    }

    func didOpenWindow(_ window: WindowState) { profiles[window.space.id]?.didOpenWindow(window) }
    func didCloseWindow(_ window: WindowState) { profiles.values.forEach { $0.didCloseWindow(window) } }
    func didFocusWindow(_ window: WindowState?) { profiles.values.forEach { $0.didFocusWindow(window) } }
    func didSwitchSpace(in window: WindowState, from previous: Space) {
        profiles[previous.id]?.didCloseWindow(window)
        profiles[window.space.id]?.didOpenWindow(window)
        didFocusWindow(state?.keyWindow)
    }

    func forget(_ space: Space) {
        clearOptionalGrants(spaceID: space.id)
        let profile = profiles.removeValue(forKey: space.id)
        profile?.stop()
        let controller = profile?.controller ?? WKWebExtensionController(configuration: .init(identifier: space.id))
        Task {
            await profile?.ready()
            let types = WKWebExtensionController.allExtensionDataTypes
            let records = await controller.dataRecords(ofTypes: types)
            await controller.removeData(ofTypes: types, from: records)
        }
    }

    private func clearOptionalGrants(spaceID: UUID, extensionIDs: Set<String>? = nil) {
        let prefix = "FeatherExtensionPermissions.\(spaceID.uuidString)."
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let id = String(key.dropFirst(prefix.count)).split(separator: ".").first.map(String.init)
            if extensionIDs == nil || id.map({ extensionIDs!.contains($0) }) == true {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func showOptions(id: String, in space: Space, dataStore: WKWebsiteDataStore, ephemeral: Bool) async throws {
        let profile = profile(for: space, dataStore: dataStore, ephemeral: ephemeral)
        profile.synchronize()
        await profile.ready()
        guard let context = profile.context(id: id), let url = context.optionsPageURL else {
            throw BrowserExtensionProfile.failure("This extension is disabled, could not load, or has no options page.")
        }
        _ = try profile.showPage(url, context: context)
    }

    func performAction(id: String, in space: Space, dataStore: WKWebsiteDataStore, ephemeral: Bool) async throws {
        let profile = profile(for: space, dataStore: dataStore, ephemeral: ephemeral)
        profile.synchronize()
        await profile.ready()
        guard let context = profile.context(id: id) else {
            throw BrowserExtensionProfile.failure("Enable this extension in Feather Settings → Extensions first.")
        }
        let tab = state?.keyWindow?.activeTab.flatMap { profile.adapter(for: $0) }
        if context.action(for: tab)?.isEnabled == true {
            context.performAction(for: tab)
        } else if let url = context.optionsPageURL {
            _ = try profile.showPage(url, context: context)
        } else {
            state?.toasts.show("This extension runs in the background", symbol: "puzzlepiece.extension")
        }
    }
}

private final class BrowserExtensionProfile: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    private weak var space: Space?
    private weak var state: BrowserState?
    private let store: WebExtensionStore
    private let ephemeral: Bool
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var versions: [String: String] = [:]
    private var tabAdapters: [UUID: WebExtensionTabAdapter] = [:]
    private var auxiliaryTabs: [ObjectIdentifier: WebExtensionTabAdapter] = [:]
    private var windowAdapters: [UUID: WebExtensionWindowAdapter] = [:]
    private var panels: [String: ExtensionPageWindow] = [:]
    private var update: Task<Void, Never>?
    private var scheduledRevision: Int?
    private var stopped = false
    private var active: WebExtensionTabAdapter?

    init(space: Space, state: BrowserState?, store: WebExtensionStore, dataStore: WKWebsiteDataStore, ephemeral: Bool) {
        self.space = space
        self.state = state
        self.store = store
        self.ephemeral = ephemeral
        let configuration = ephemeral ? WKWebExtensionController.Configuration.nonPersistent() : .init(identifier: space.id)
        configuration.defaultWebsiteDataStore = dataStore
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = dataStore
        configuration.webViewConfiguration = webConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(optionalPermissionsRemoved(_:)),
            name: WKWebExtensionContext.grantedPermissionsWereRemovedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(optionalPermissionsRemoved(_:)),
            name: WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextErrorsUpdated(_:)),
            name: WKWebExtensionContext.errorsDidUpdateNotification, object: nil)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "dev.nesbes.Feather.Extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func synchronize() {
        guard scheduledRevision != store.revision else { return }
        scheduledRevision = store.revision
        let previous = update
        update = Task { [weak self] in
            await previous?.value
            guard let self, !self.stopped else { return }
            let entries = self.store.entries.filter(\.enabled)
            let ids = Set(entries.map(\.id))
            for (id, context) in self.contexts where !ids.contains(id) || self.versions[id] != entries.first(where: { $0.id == id })?.version {
                self.closePanels(for: context)
                try? self.controller.unload(context)
                self.contexts[id] = nil
                self.versions[id] = nil
            }
            for entry in entries where self.contexts[entry.id] == nil {
                do {
                    let resource = try await WKWebExtension(resourceBaseURL: self.store.resourceURL(for: entry))
                    // KVC avoids the SDK's WKNSError → Swift.Error bridge on malformed manifests.
                    if let error = (resource.value(forKey: "errors") as? [NSError])?.first { throw error }
                    guard !self.stopped, self.store.entries.contains(where: { $0.id == entry.id && $0.enabled }) else { continue }
                    let context = WKWebExtensionContext(for: resource)
                    context.uniqueIdentifier = entry.id
                    context.baseURL = URL(string: "webkit-extension://\(entry.id)/")!
                    context.isInspectable = true
                    context.hasAccessToPrivateData = self.ephemeral
                    for permission in resource.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
                    for pattern in resource.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
                    self.restoreOptionalPermissions(for: context)
                    // Local file access needs a separate browser capability.
                    // Do not infer it from a web-site permission approval.
                    if let files = try? WKWebExtension.MatchPattern(string: "file:///*") {
                        context.setPermissionStatus(.deniedExplicitly, for: files)
                    }
                    try self.controller.load(context)
                    self.contexts[entry.id] = context
                    self.versions[entry.id] = entry.version
                    if resource.hasBackgroundContent { try await self.loadBackground(context) }
                } catch {
                    if let context = self.contexts.removeValue(forKey: entry.id) {
                        self.closePanels(for: context)
                        try? self.controller.unload(context)
                    }
                    self.versions[entry.id] = nil
                    self.store.lastError = "\(entry.name): \(error.localizedDescription)"
                    NSLog("Extension %@ could not load: %@", entry.name, error.localizedDescription)
                }
            }
            // Removed extensions lose their native storage too; disabled ones retain it.
            let installedIDs = Set(self.store.entries.map(\.id))
            let types = WKWebExtensionController.allExtensionDataTypes
            let records = await self.controller.dataRecords(ofTypes: types)
            let removed = records.filter { !installedIDs.contains($0.uniqueIdentifier) }
            if !removed.isEmpty { await self.controller.removeData(ofTypes: types, from: removed) }
        }
    }

    func ready() async { await update?.value }
    func context(id: String) -> WKWebExtensionContext? { contexts[id] }

    private func loadBackground(_ context: WKWebExtensionContext) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            Task { @MainActor in
                do {
                    try await context.loadBackgroundContent()
                    guard !finished else { return }
                    finished = true
                    continuation.resume()
                } catch {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !finished else { return }
                finished = true
                continuation.resume(throwing: Self.failure("The extension background did not start within 8 seconds. It has been unloaded so browsing can continue."))
            }
        }
    }

    @objc private func contextErrorsUpdated(_ notification: Notification) {
        guard let context = notification.object as? WKWebExtensionContext,
              contexts[context.uniqueIdentifier] === context,
              let errors = context.value(forKey: "errors") as? NSArray,
              let error = errors.firstObject as? NSError else { return }
        store.lastError = "\(context.webExtension.displayName ?? "Extension"): \(error.localizedDescription)"
    }

    func stop() {
        stopped = true
        NotificationCenter.default.removeObserver(self)
        Array(panels.values).forEach { $0.close() }
        contexts.values.forEach { try? controller.unload($0) }
        contexts.removeAll()
    }

    func adapter(for tab: Tab) -> WebExtensionTabAdapter? {
        guard let state, let space, space.contains(tab) else { return nil }
        if let adapter = tabAdapters[tab.id] { return adapter }
        let adapter = WebExtensionTabAdapter(tab: tab, state: state)
        tabAdapters[tab.id] = adapter
        assignOwner(adapter)
        controller.didOpenTab(adapter)
        return adapter
    }

    private func assignOwner(_ adapter: WebExtensionTabAdapter) {
        guard let tab = adapter.tab, let space, let state else { return }
        let model = state.window(showing: tab) ?? state.windows.first(where: { $0.space === space })
        adapter.owner = model.map(windowAdapter)
    }

    private func windowAdapter(_ model: WindowState) -> WebExtensionWindowAdapter {
        if let adapter = windowAdapters[model.id] { return adapter }
        let adapter = WebExtensionWindowAdapter(model: model, state: state)
        adapter.privateBrowsing = ephemeral
        adapter.tabProvider = { [weak self, weak model, weak adapter] in
            guard let self, let model, let space = self.space, let state = self.state else { return [] }
            return space.allTabs.compactMap { tab in
                let owner = state.window(showing: tab) ?? state.windows.first(where: { $0.space === space })
                guard owner === model, let entry = self.adapter(for: tab) else { return nil }
                entry.owner = adapter
                return entry
            }
        }
        adapter.activeTabProvider = { [weak self, weak model] in model?.activeTab.flatMap { self?.adapter(for: $0) } }
        windowAdapters[model.id] = adapter
        controller.didOpenWindow(adapter)
        return adapter
    }

    func didOpenWindow(_ model: WindowState) { _ = windowAdapter(model) }

    func didCloseWindow(_ model: WindowState) {
        guard let old = windowAdapters.removeValue(forKey: model.id) else { return }
        let moving = space?.allTabs.compactMap { tabAdapters[$0.id] }.filter { $0.owner === old } ?? []
        for (index, tab) in moving.enumerated() {
            assignOwner(tab)
            controller.didMoveTab(tab, from: index, in: old)
        }
        controller.didCloseWindow(old)
    }

    func didFocusWindow(_ model: WindowState?) {
        let focused = model.flatMap { $0.space === space ? windowAdapter($0) : nil }
        controller.didFocusWindow(focused)
    }

    @discardableResult
    func track(_ view: WKWebView) -> WebExtensionTabAdapter {
        let key = ObjectIdentifier(view)
        if let entry = auxiliaryTabs[key] { return entry }
        let entry = WebExtensionTabAdapter(webView: view)
        auxiliaryTabs[key] = entry
        controller.didOpenTab(entry)
        return entry
    }

    func bind(_ view: WKWebView, to tab: Tab) {
        let key = ObjectIdentifier(view)
        if let existing = tabAdapters[tab.id] {
            if let temporary = auxiliaryTabs.removeValue(forKey: key) { controller.didCloseTab(temporary) }
            existing.auxiliaryWebView = nil
            assignOwner(existing)
            controller.didChangeTabProperties([.loading, .URL], for: existing)
        } else if let entry = auxiliaryTabs.removeValue(forKey: key) {
            entry.tab = tab
            entry.state = state
            entry.auxiliaryWebView = nil
            tabAdapters[tab.id] = entry
            assignOwner(entry)
        } else {
            _ = adapter(for: tab)
        }
    }

    func untrack(_ view: WKWebView) {
        if let entry = auxiliaryTabs.removeValue(forKey: ObjectIdentifier(view)) { controller.didCloseTab(entry) }
        // Model adapters survive tab sleeping and acquire the new view on wake.
    }

    func didClose(_ tab: Tab) {
        guard let adapter = tabAdapters.removeValue(forKey: tab.id) else { return }
        controller.didCloseTab(adapter)
    }

    func didOpen(_ tab: Tab) { _ = adapter(for: tab) }

    func didSelect(_ tab: Tab) {
        guard let adapter = adapter(for: tab) else { return }
        assignOwner(adapter)
        controller.didActivateTab(adapter, previousActiveTab: active)
        active = adapter
    }

    func didChange(_ tab: Tab, properties: WKWebExtension.TabChangedProperties) {
        guard let adapter = tabAdapters[tab.id] else { return }
        controller.didChangeTabProperties(properties, for: adapter)
    }

    private func closePanels(for context: WKWebExtensionContext) {
        Array(panels.values).filter { $0.context === context }.forEach { $0.close() }
    }

    @discardableResult
    func showPage(_ url: URL, context: WKWebExtensionContext, popup: WKWebExtension.Action? = nil) throws -> WebExtensionTabAdapter {
        let key = context.uniqueIdentifier + (popup == nil ? ":options" : ":action")
        if let existing = panels[key] {
            if popup == nil, existing.view.url != url { existing.view.load(URLRequest(url: url)) }
            existing.window.makeKeyAndOrderFront(nil)
            return existing.tab
        }
        let panel = try ExtensionPageWindow(url: url, context: context, popup: popup)
        panel.openWebsite = { [weak self] url, configuration in self?.open(url, configuration: configuration) }
        panel.download = { [weak self] download in self?.state?.downloads.track(download) }
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            if !panel.isActionPopup {
                self.controller.didCloseTab(panel.tab, windowIsClosing: true)
                self.controller.didCloseWindow(panel.adapter)
            }
            self.panels[key] = nil
        }
        panels[key] = panel
        // Action popups operate on their originating website tab. Registering
        // them as browser tabs breaks activeTab/currentWindow queries.
        if !panel.isActionPopup {
            controller.didOpenWindow(panel.adapter)
            controller.didOpenTab(panel.tab)
        }
        panel.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return panel.tab
    }

    @discardableResult
    private func open(_ url: URL, configuration: WKWebViewConfiguration? = nil, newWindow: Bool = false) -> WebExtensionTabAdapter? {
        if let context = controller.extensionContext(for: url) { return try? showPage(url, context: context) }
        guard ["http", "https", "about"].contains(url.scheme?.lowercased() ?? ""), let state, let space else { return nil }
        let window = newWindow ? state.newWindow(space: space)
            : state.windows.first(where: { $0 === state.keyWindow && $0.space === space })
                ?? state.windows.first(where: { $0.space === space }) ?? state.newWindow(space: space)
        let tab = state.openTab(url, in: window, configuration: configuration)
        return adapter(for: tab)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        let browserWindows = state?.windows.filter { $0.space === space }.map(windowAdapter) ?? []
        return browserWindows + panels.values.filter { !$0.isActionPopup }.map(\.adapter)
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        if let panel = panels.values.first(where: { $0.window.isKeyWindow && !$0.isActionPopup }) { return panel.adapter }
        guard let model = state?.keyWindow, model.space === space else { return nil }
        return windowAdapter(model)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext,
                                completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let url = context.optionsPageURL else { throw Self.failure("This extension has no options page.") }
            try showPage(url, context: context)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let view = action.popupWebView else { throw Self.failure("The extension popup is unavailable.") }
            // A newly created popup may not have committed its URL yet.
            try showPage(view.url ?? context.baseURL, context: context, popup: action)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        let url = configuration.url ?? URL(string: "about:blank")!
        if let targetContext = controller.extensionContext(for: url) {
            do { completionHandler(try showPage(url, context: targetContext), nil) }
            catch { completionHandler(nil, error) }
            return
        }
        guard ["http", "https", "about"].contains(url.scheme?.lowercased() ?? ""), let state, let space else {
            completionHandler(nil, Self.failure("The extension could not open this page.")); return
        }
        let requested = (configuration.window as? WebExtensionWindowAdapter)?.model
        guard requested == nil || requested?.space === space else {
            completionHandler(nil, Self.failure("The requested window belongs to another Space.")); return
        }
        let window = requested ?? state.windows.first(where: { $0 === state.keyWindow && $0.space === space })
            ?? state.windows.first(where: { $0.space === space }) ?? state.newWindow(space: space)
        let parent = (configuration.parentTab as? WebExtensionTabAdapter)?.tab
        let tab = state.openTab(url, in: window, background: !configuration.shouldBeActive,
                                after: parent.flatMap { space.contains($0) ? $0 : nil })
        if configuration.shouldBePinned { state.togglePin(tab) }
        if configuration.shouldBeMuted { tab.isMuted = true; state.media.applyMute(to: tab) }
        completionHandler(adapter(for: tab), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void) {
        guard !configuration.shouldBePrivate || ephemeral else {
            completionHandler(nil, Self.failure("Feather does not provide private extension windows.")); return
        }
        var first: WebExtensionTabAdapter?
        let urls = configuration.tabURLs.isEmpty ? [URL(string: "about:blank")!] : configuration.tabURLs
        for (index, url) in urls.enumerated() {
            let tab = open(url, newWindow: index == 0)
            if first == nil { first = tab }
        }
        guard let owner = first?.owner else { completionHandler(nil, Self.failure("The extension could not open this window.")); return }
        completionHandler(owner, nil)
    }

    private func optionalKey(_ context: WKWebExtensionContext, _ kind: String) -> String {
        "FeatherExtensionPermissions.\(space?.id.uuidString ?? "ephemeral").\(context.uniqueIdentifier).\(kind)"
    }

    @objc private func optionalPermissionsRemoved(_ notification: Notification) {
        guard !ephemeral, let context = notification.object as? WKWebExtensionContext,
              contexts[context.uniqueIdentifier] === context else { return }
        let defaults = UserDefaults.standard
        let apis = Set(context.grantedPermissions.keys.map(\.rawValue))
        let sites = Set(context.grantedPermissionMatchPatterns.keys.map(\.string))
        let apiKey = optionalKey(context, "apis")
        let siteKey = optionalKey(context, "sites")
        defaults.set((defaults.stringArray(forKey: apiKey) ?? []).filter { apis.contains($0) }, forKey: apiKey)
        defaults.set((defaults.stringArray(forKey: siteKey) ?? []).filter { sites.contains($0) }, forKey: siteKey)
    }

    private func restoreOptionalPermissions(for context: WKWebExtensionContext) {
        guard !ephemeral else { return }
        for raw in UserDefaults.standard.stringArray(forKey: optionalKey(context, "apis")) ?? [] {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: raw))
        }
        for raw in UserDefaults.standard.stringArray(forKey: optionalKey(context, "sites")) ?? [] {
            if let pattern = try? WKWebExtension.MatchPattern(string: raw) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        }
    }

    private func approve(_ description: String, context: WKWebExtensionContext) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow additional access for \(context.webExtension.displayName ?? "this extension")?"
        alert.informativeText = description
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        guard approve(permissions.map(\.rawValue).sorted().joined(separator: "\n"), context: context) else { completionHandler([], nil); return }
        if !ephemeral {
            let key = optionalKey(context, "apis")
            UserDefaults.standard.set(Array(Set((UserDefaults.standard.stringArray(forKey: key) ?? []) + permissions.map(\.rawValue))), forKey: key)
        }
        completionHandler(permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let allowedPatterns = Set(patterns.filter { $0.scheme != "file" })
        guard !allowedPatterns.isEmpty,
              approve(allowedPatterns.map(\.string).sorted().joined(separator: "\n"), context: context) else { completionHandler([], nil); return }
        if !ephemeral {
            let key = optionalKey(context, "sites")
            UserDefaults.standard.set(Array(Set((UserDefaults.standard.stringArray(forKey: key) ?? []) + allowedPatterns.map(\.string))), forKey: key)
        }
        completionHandler(allowedPatterns, nil)
    }
}

/// Extension-origin pages need the context's configuration and their own
/// delegates for file pickers, downloads, dialogs, links and window.open.
private final class ExtensionPageWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let window: NSWindow
    let view: WKWebView
    let context: WKWebExtensionContext
    let adapter: WebExtensionWindowAdapter
    let tab: WebExtensionTabAdapter
    var onClose: (() -> Void)?
    var openWebsite: ((URL, WKWebViewConfiguration?) -> WebExtensionTabAdapter?)?
    var download: ((WKDownload) -> Void)?
    private let popup: WKWebExtension.Action?
    var isActionPopup: Bool { popup != nil }

    init(url: URL, context: WKWebExtensionContext, popup: WKWebExtension.Action?) throws {
        self.context = context
        self.popup = popup
        if let popupView = popup?.popupWebView { view = popupView }
        else {
            guard let configuration = context.webViewConfiguration else { throw BrowserExtensionProfile.failure("The extension is not loaded.") }
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 740), configuration: configuration)
        }
        let size = popup == nil ? NSSize(width: 1000, height: 740) : NSSize(width: 420, height: 600)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = context.webExtension.displayName ?? "Extension"
        window.minSize = NSSize(width: 280, height: 200)
        window.isReleasedWhenClosed = false
        window.contentView = view
        adapter = WebExtensionWindowAdapter(nativeWindow: window)
        tab = WebExtensionTabAdapter(webView: view, owner: adapter)
        super.init()
        adapter.tabProvider = { [weak tab] in tab.map { [$0] } ?? [] }
        adapter.activeTabProvider = { [weak tab] in tab }
        view.isInspectable = true
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setAccessibilityIdentifier("feather.extension.\(context.uniqueIdentifier)")
        window.delegate = self
        window.center()
        if popup == nil { view.load(URLRequest(url: url)) }
    }

    func close() { window.close() }
    func windowWillClose(_ notification: Notification) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        popup?.closePopup()
        onClose?()
        onClose = nil
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url else { return .cancel }
        if url.scheme == context.baseURL.scheme && url.host == context.baseURL.host || url.absoluteString == "about:blank" { return .allow }
        _ = openWebsite?(url, nil)
        return .cancel
    }

    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") ? .download : .allow
    }
    func webView(_ view: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { self.download?(download) }
    func webView(_ view: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { self.download?(download) }
    func webViewDidClose(_ view: WKWebView) { close() }

    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        // Extension-bound configurations cannot navigate to ordinary websites.
        // The destination gets the Space's normal configuration through open().
        _ = openWebsite?(url, nil)
        return nil
    }

    func webView(_ view: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private func alert(_ message: String, buttons: [String]) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = context.webExtension.displayName ?? "Extension"
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return await alert.beginSheetModal(for: window)
    }
    func webView(_ view: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await alert(message, buttons: ["OK"])
    }
    func webView(_ view: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await alert(message, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }
    func webView(_ view: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
