import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var state: BrowserState!
    private var windowControllers: [UUID: BrowserWindowController] = [:]
    private var settingsWindow: NSWindow?
    private var memoryPanel: NSPanel?
    private var benchmark: BenchmarkRunner?
    private var pendingURLs: [URL] = []
    private var agentBridge: AgentBridge?
    private weak var tourWindow: BrowserWindowController?
    private var welcomePreview = false
    private var launchSplashPending = false
    private var allowsLaunchSplash = true
    private weak var splashWindow: BrowserWindowController?
    private var pendingLaunchFollowUp: (() -> Void)?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Refresh the Dock icon after a local rebuild, even if Launch Services
        // still has the previous build's icon cached.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.mainMenu = MainMenu.build()
        NSApp.mainMenu?.item(withTitle: "Extensions")?.submenu?.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { benchmark = try BenchmarkRunner.fromArguments() }
        catch {
            // Reject isolated experiment configuration before restoring any browser state.
            fputs("Rejected benchmark configuration: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard
        welcomePreview = arguments.contains("-FeatherWelcomePreview") && defaults.bool(forKey: "FeatherWelcomePreview")
        let automated = benchmark != nil || (arguments.contains("-FeatherAgentBridge") && defaults.bool(forKey: "FeatherAgentBridge"))
        allowsLaunchSplash = !automated && !welcomePreview
        launchSplashPending = allowsLaunchSplash
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Feather/session.json")
        // Check before restore creates Home and schedules its first save.
        let firstRun = FirstRunPolicy.shouldPresent(
            completedVersion: defaults.integer(forKey: FirstRunPolicy.completedKey),
            hasSavedSession: FileManager.default.fileExists(atPath: support.path),
            isAutomated: automated, previewRequested: welcomePreview,
            hasStartedWelcome: defaults.bool(forKey: FirstRunPolicy.startedKey))
        if firstRun && !welcomePreview { defaults.set(true, forKey: FirstRunPolicy.startedKey) }
        state = BrowserState(settings: .shared, persistent: (benchmark == nil || benchmark?.requiresPersistentState == true) && !welcomePreview)
        BrowserClickSoundController.shared.start(settings: state.settings)
        state.onOpenWindow = { [weak self] model in self?.showWindow(for: model) }
        state.lifecycle.factory.ephemeral = (benchmark != nil && benchmark?.requiresPersistentState != true) || welcomePreview
        state.lifecycle.blocker.start()
        state.memory.start()
        PasswordController.shared.state = state
        CookieConsent.shared.state = state
        YouTubeExtras.shared.state = state
        ReadAloud.shared.state = state
        state.restore()
        agentBridge = AgentBridge(state: state)
        // Deliberately session-scoped; ordinary launches never restore agent access.
        if ProcessInfo.processInfo.arguments.contains("-FeatherAgentBridge"),
           UserDefaults.standard.bool(forKey: "FeatherAgentBridge") { enableAgentAccess() }
        benchmark?.start(with: state)
        if !pendingURLs.isEmpty {
            application(NSApp, open: pendingURLs)
            pendingURLs = []
        }
        NSApp.activate()
        let followUp = { [weak self] in
            guard let self else { return }
            let complete = { [weak self] in
                guard let self else { return }
                if firstRun { self.presentWelcome(completesFirstRun: !self.welcomePreview) }
                else if !self.welcomePreview && !automated { Passkeys.requestAuthorizationIfNeeded() }
            }
            if NSApp.isActive { complete() }
            else { self.pendingLaunchFollowUp = complete }
        }
        if let splashWindow { splashWindow.startLaunchSplash(onFinish: followUp) }
        else { followUp() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let followUp = pendingLaunchFollowUp
        pendingLaunchFollowUp = nil
        followUp?()
    }

    /// Links clicked in other apps (Feather as the default browser) and .html files.
    /// When they launch Feather, they arrive before the session is restored, so they wait for it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard state != nil else {
            pendingURLs += urls
            return
        }
        let window = state.keyWindow ?? state.windows.first ?? state.newWindow()
        for url in urls { state.openTab(url, in: window) }
        windowControllers[window.id]?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasVisibleBrowser = windowControllers.values.contains { $0.window?.isVisible == true }
        if !hasVisibleBrowser {
            launchSplashPending = allowsLaunchSplash
            state.newWindow()
            splashWindow?.startLaunchSplash(onFinish: {})
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        pendingLaunchFollowUp = nil
        BrowserClickSoundController.shared.stop()
        agentBridge?.stop()
        state?.saveNow(synchronously: true)
    }

    private func showWindow(for model: WindowState) {
        let controller = BrowserWindowController(model: model, state: state)
        if launchSplashPending {
            launchSplashPending = false
            controller.prepareLaunchSplash()
            splashWindow = controller
        }
        controller.onClose = { [weak self] in self?.windowControllers[model.id] = nil }
        windowControllers[model.id] = controller
        controller.showWindow(nil)
    }

    // MARK: App-level actions

    @objc func showWelcomeGuide(_ sender: Any?) {
        presentWelcome(completesFirstRun: false)
    }

    private func presentWelcome(completesFirstRun: Bool) {
        if let tourWindow, tourWindow.isWelcomeTourActive {
            tourWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = state.keyWindow ?? state.windows.first ?? state.newWindow()
        guard let browser = windowControllers[model.id] else { return }
        tourWindow = browser
        browser.window?.makeKeyAndOrderFront(nil)
        browser.startWelcomeTour { [weak self] in
            guard let self else { return }
            if completesFirstRun {
                UserDefaults.standard.set(FirstRunPolicy.currentVersion, forKey: FirstRunPolicy.completedKey)
                UserDefaults.standard.removeObject(forKey: FirstRunPolicy.startedKey)
            }
            self.tourWindow = nil
            if completesFirstRun { Passkeys.requestAuthorizationIfNeeded() }
        }
    }

    @objc func toggleAgentAccess(_ sender: Any?) {
        if agentBridge?.isRunning == true {
            agentBridge?.stop()
            state.agentAccessEnabled = false
            state.toasts.show("Agent access is off", symbol: "terminal", in: state.keyWindow?.id)
        } else { enableAgentAccess() }
    }

    private func enableAgentAccess() {
        do {
            try agentBridge?.start()
            state.agentAccessEnabled = agentBridge?.isRunning == true
            state.toasts.show("Agent access is on for this session", symbol: "terminal", in: state.keyWindow?.id,
                              actions: [.init(title: "Turn Off") { [weak self] in self?.toggleAgentAccess(nil) }], duration: 6)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not enable agent access"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func copyAgentSocketPath(_ sender: Any?) {
        guard let path = agentBridge?.socketPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeFocusedWindowOrTab(_:)):
            let browser = windowControllers.values.first { $0.window === NSApp.keyWindow }
            item.title = browser?.model.activeTab != nil ? "Close Tab" : "Close Window"
            return NSApp.keyWindow != nil
        case #selector(toggleAgentAccess(_:)):
            item.title = agentBridge?.isRunning == true ? "Agent Access Is On" : "Enable Agent Access for This Session"
            item.state = agentBridge?.isRunning == true ? .on : .off
            return agentBridge != nil
        case #selector(copyAgentSocketPath(_:)):
            return agentBridge?.isRunning == true
        default: return true
        }
    }

    @objc func newWindow(_ sender: Any?) {
        state.newWindow()
    }

    @objc func closeFocusedWindowOrTab(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow else { return }
        if let browser = windowControllers.values.first(where: { $0.window === keyWindow }) {
            browser.closeTab(sender)
        } else {
            keyWindow.performClose(sender)
        }
    }

    @objc func showPasswordsSettings(_ sender: Any?) {
        state.settings.settingsPane = "passwords"
        showSettings(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: state.settings)))
            window.title = "Feather Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.contentMinSize = NSSize(width: 820, height: 560)
            let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 900)
            window.setContentSize(NSSize(width: min(900, screen.width - 64), height: min(680, screen.height - 96)))
            window.setFrameAutosaveName("FeatherSettings")
            if !window.setFrameUsingName("FeatherSettings") { window.center() }
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showExtensionsSettings(_ sender: Any?) {
        state.settings.settingsPane = "extensions"
        showSettings(sender)
    }

    @objc func openExtension(_ sender: Any?) { runExtension(sender, options: false) }
    @objc func showExtensionOptions(_ sender: Any?) { runExtension(sender, options: true) }

    private func runExtension(_ sender: Any?, options: Bool) {
        let id = (sender as? NSMenuItem)?.representedObject as? String ?? sender as? String
        guard let id else { return }
        let window = state.keyWindow ?? state.windows.first ?? state.newWindow()
        let factory = state.lifecycle.factory
        Task {
            do {
                if options {
                    try await factory.extensions.showOptions(id: id, in: window.space,
                        dataStore: factory.dataStore(for: window.space), ephemeral: factory.ephemeral)
                } else {
                    try await factory.extensions.performAction(id: id, in: window.space,
                        dataStore: factory.dataStore(for: window.space), ephemeral: factory.ephemeral)
                }
            } catch {
                WebExtensionStore.shared.lastError = error.localizedDescription
                let alert = NSAlert()
                alert.messageText = "Could not open extension"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Extensions" else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "Manage Extensions…", action: #selector(showExtensionsSettings(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let enabled = WebExtensionStore.shared.entries.filter(\.enabled)
        for entry in enabled {
            let item = menu.addItem(withTitle: entry.name, action: #selector(openExtension(_:)), keyEquivalent: "")
            item.representedObject = entry.id
            item.target = self
        }
        if enabled.isEmpty {
            let item = menu.addItem(withTitle: "No enabled extensions", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
    }

    @objc func showMemoryPanel(_ sender: Any?) {
        if memoryPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Memory"
            panel.contentViewController = NSHostingController(rootView: MemoryPanelView(state: state))
            panel.isReleasedWhenClosed = false
            panel.center()
            memoryPanel = panel
        }
        memoryPanel?.makeKeyAndOrderFront(nil)
    }

    @objc func sleepBackgroundTabs(_ sender: Any?) {
        Task { await state.lifecycle.sleepAllBackgroundTabs() }
    }

    @objc func simulateMemoryPressure(_ sender: Any?) {
        Task { await state.lifecycle.evaluate(pressure: .critical) }
    }
}

/// The main menu, built in code. Window commands use a nil target so they reach
/// the key window's `BrowserWindowController` through the responder chain.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Feather", [
            item("About Feather", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide Feather", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Feather", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"),
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("Open Location…", #selector(BrowserWindowController.openLocation(_:)), "l"),
            .separator(),
            item("Close Tab", #selector(AppDelegate.closeFocusedWindowOrTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Page URL", #selector(BrowserWindowController.copyPageURL(_:)), "c", [.command, .shift]),
            item("Copy Link as Markdown", #selector(BrowserWindowController.copyMarkdownLink(_:)), "c", [.command, .option, .shift]),
            item("Find…", #selector(BrowserWindowController.findInPage(_:)), "f"),
            item("Find Next", #selector(BrowserWindowController.findNextMatch(_:)), "g"),
            item("Find Previous", #selector(BrowserWindowController.findPreviousMatch(_:)), "g", [.command, .shift]),
        ]))
        main.addItem(submenu("View", [
            item("Hide Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s"),
            item("Split View", #selector(BrowserWindowController.toggleSplitView(_:)), "=", [.command, .shift]),
            item("Show Reader", #selector(BrowserWindowController.toggleReader(_:)), "r", [.command, .shift]),
            item("Listen to Page", #selector(BrowserWindowController.listenToPage(_:)), "l", [.command, .option]),
            .separator(),
            item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"),
            item("Reload Ignoring Cache", #selector(BrowserWindowController.reloadFromOrigin(_:)), "r", [.command, .option]),
            item("Stop", #selector(BrowserWindowController.stopLoading(_:)), "."),
            .separator(),
            item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Block Ads & Trackers on This Site", #selector(BrowserWindowController.toggleContentBlocking(_:))),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        main.addItem(submenu("History", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
        ]))
        var tabItems: [NSMenuItem] = [
            item("Pin Tab", #selector(BrowserWindowController.togglePin(_:)), "d"),
            item("Add to Favorites", #selector(BrowserWindowController.toggleFavorite(_:)), "d", [.command, .shift]),
            item("Show Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "}"),
            item("Show Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "{"),
            item("Clear Unpinned Tabs", #selector(BrowserWindowController.clearTabs(_:)), "k", [.command, .shift]),
            item("Group Tabs Now", #selector(BrowserWindowController.groupTabsNow(_:)), "g", [.command, .option]),
            item("Mute Tab", #selector(BrowserWindowController.toggleMute(_:)), "m", [.command, .shift]),
            .separator(),
        ]
        for number in 1...9 {
            let entry = item(number == 9 ? "Last Tab" : "Tab \(number)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\(number)")
            entry.tag = number - 1
            tabItems.append(entry)
        }
        tabItems += [
            .separator(),
            item("Unload Background Tabs", #selector(AppDelegate.sleepBackgroundTabs(_:)), "z", [.command, .option]),
            item("Memory…", #selector(AppDelegate.showMemoryPanel(_:)), "m", [.command, .option]),
        ]
        main.addItem(submenu("Tabs", tabItems))
        var spaceItems: [NSMenuItem] = [item("New Space…", #selector(BrowserWindowController.newSpace(_:))), .separator()]
        for number in 1...9 {
            let entry = item("Space \(number)", #selector(BrowserWindowController.switchSpaceByNumber(_:)), "\(number)", [.control])
            entry.tag = number - 1
            spaceItems.append(entry)
        }
        main.addItem(submenu("Spaces", spaceItems))
        main.addItem(submenu("Extensions", [item("Manage Extensions…", #selector(AppDelegate.showExtensionsSettings(_:)))]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)
        main.addItem(submenu("Develop", [
            item("Enable Agent Access for This Session", #selector(AppDelegate.toggleAgentAccess(_:))),
            item("Copy Agent Socket Path", #selector(AppDelegate.copyAgentSocketPath(_:))),
        ]))
        main.addItem(submenu("Debug", [
            item("Simulate Memory Pressure", #selector(AppDelegate.simulateMemoryPressure(_:))),
        ]))
        let help = submenu("Help", [
            item("Welcome to Feather…", #selector(AppDelegate.showWelcomeGuide(_:))),
        ])
        NSApp.helpMenu = help.submenu
        main.addItem(help)
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
