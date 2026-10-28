// Compiled with the exact production extension manager, adapters, and store.
// Stubs below supply only Feather's browser model/factory integration seam.
import AppKit
import Foundation
import Network
import WebKit

@MainActor final class Tab {
    let id = UUID()
    var url: URL?
    var pendingURL: URL?
    var webView: WKWebView?
    var displayTitle = "Host fixture"
    var isLoading = false
    var isPlayingAudio = false
    var isMuted = false
    var isReaderable = false
    var isReaderOpen = false
    var favoriteID: UUID?
    init(url: URL?) { self.url = url; pendingURL = url }
}
@MainActor final class Space {
    let id = UUID()
    var allTabs: [Tab] = []
    var pinned: [Tab] = []
    func contains(_ tab: Tab) -> Bool { allTabs.contains { $0 === tab } }
    func isPinned(_ tab: Tab) -> Bool { pinned.contains { $0 === tab } }
}
@MainActor final class WindowState {
    let id = UUID()
    let space: Space
    var activeTab: Tab?
    let nativeWindow: NSWindow
    var visibleTabs: [Tab] { activeTab.map { [$0] } ?? [] }
    var currentFrame: NSRect? { nativeWindow.frame }
    func isShowing(_ tab: Tab) -> Bool { activeTab === tab }
    init(space: Space) {
        self.space = space
        nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        nativeWindow.isReleasedWhenClosed = false
        nativeWindow.title = "Isolated production extension host fixture"
    }
}
@MainActor final class HarnessSettings { var readerFontSize = 17.0 }
@MainActor final class HarnessToasts { var messages: [String] = []; func show(_ message: String, symbol: String) { messages.append(message) } }
@MainActor final class HarnessDownloads { func track(_ download: WKDownload) {} }
@MainActor final class MediaController { func applyMute(to tab: Tab) {} }
@MainActor enum ReaderMode { static func toggle(in view: WKWebView, fontSize: Double) async -> Bool { false } }

@MainActor final class TabLifecycle {
    unowned let state: BrowserState
    init(state: BrowserState) { self.state = state }
    func ensureLive(_ tab: Tab) {
        guard tab.webView == nil, let space = state.space(of: tab) else { return }
        _ = state.makeView(tab, space: space, configuration: nil)
    }
    func load(_ url: URL, fallbacks: [URL], in tab: Tab) {
        tab.url = url; tab.pendingURL = url
        ensureLive(tab)
        guard let view = tab.webView else { return }
        Task { @MainActor in await state.manager.prepare(in: view); view.load(URLRequest(url: url)) }
    }
}

@MainActor final class BrowserState {
    let manager: BrowserExtensionManager
    var spaces: [Space] = []
    var windows: [WindowState] = []
    var keyWindow: WindowState?
    var stores: [UUID: WKWebsiteDataStore] = [:]
    var inheritedConfigurations = 0
    let settings = HarnessSettings()
    let toasts = HarnessToasts()
    let downloads = HarnessDownloads()
    let media = MediaController()
    lazy var lifecycle = TabLifecycle(state: self)
    init(manager: BrowserExtensionManager) { self.manager = manager; manager.state = self }
    func dataStore(_ space: Space) -> WKWebsiteDataStore {
        if let existing = stores[space.id] { return existing }
        let store = WKWebsiteDataStore.nonPersistent()
        stores[space.id] = store
        return store
    }
    func space(of tab: Tab) -> Space? { spaces.first { $0.contains(tab) } }
    func window(showing tab: Tab) -> WindowState? { windows.first { $0.isShowing(tab) } }
    func scheduleSave() {}
    @discardableResult func newWindow(space: Space) -> WindowState {
        if !spaces.contains(where: { $0 === space }) { spaces.append(space) }
        let model = WindowState(space: space)
        windows.append(model); keyWindow = model
        model.nativeWindow.makeKeyAndOrderFront(nil)
        return model
    }
    @discardableResult func makeView(_ tab: Tab, space: Space, configuration inherited: WKWebViewConfiguration?) -> WKWebView {
        let configuration: WKWebViewConfiguration
        if let inherited { configuration = inherited; inheritedConfigurations += 1 }
        else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore(space)
            configuration.webExtensionController = manager.controller(for: space, dataStore: configuration.websiteDataStore, ephemeral: true)
        }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500), configuration: configuration)
        tab.webView = view
        manager.track(view, in: space)
        manager.bind(view, to: tab, in: space)
        return view
    }
    @discardableResult func openTab(_ url: URL?, in window: WindowState, background: Bool = false, after anchor: Tab? = nil,
                                   configuration: WKWebViewConfiguration? = nil) -> Tab {
        let tab = Tab(url: url)
        window.space.allTabs.append(tab)
        let view = makeView(tab, space: window.space, configuration: configuration)
        manager.didOpen(tab, in: window.space)
        if !background { select(tab, in: window) }
        // As in production, WebKit owns loading an inherited window.open request.
        if configuration == nil, let url {
            Task { @MainActor in await manager.prepare(in: view); view.load(URLRequest(url: url)); tab.pendingURL = nil }
        }
        return tab
    }
    func select(_ tab: Tab, in window: WindowState) {
        keyWindow = window; window.activeTab = tab
        if let view = tab.webView { window.nativeWindow.contentView = view }
        manager.didSelect(tab, in: window.space)
    }
    func close(_ tab: Tab) {
        guard let space = space(of: tab) else { return }
        manager.didClose(tab, in: space)
        if let view = tab.webView { manager.untrack(view); view.stopLoading(); view.removeFromSuperview() }
        space.allTabs.removeAll { $0 === tab }; space.pinned.removeAll { $0 === tab }
        for window in windows where window.activeTab === tab { window.activeTab = space.allTabs.first }
        tab.webView = nil
    }
    func togglePin(_ tab: Tab) {
        guard let space = space(of: tab) else { return }
        if space.isPinned(tab) { space.pinned.removeAll { $0 === tab } } else { space.pinned.append(tab) }
        manager.didChange(tab, properties: .pinned)
    }
}

@MainActor final class HostSmoke {
    let out: URL
    let work: URL
    var listener: NWListener!
    var connections: [NWConnection] = []
    var state: BrowserState!
    var store: WebExtensionStore!
    var checks: [String: Bool] = [:]
    var observations: [String: Any] = [:]
    var finished = false
    let started = Date()
    init(out: URL, work: URL) { self.out = out; self.work = work }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.connections.append(connection)
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    MainActor.assumeIsolated {
                        let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let body = Data("<!doctype html><title>Local host fixture</title><h1>Production host integration fixture</h1>".utf8)
                        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                        if !request.isEmpty { connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() }) }
                    }
                }
            }
        }
        listener.stateUpdateHandler = { [weak self] status in
            guard case .ready = status else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.run() } catch { self.observations["fatalError"] = String(describing: error); self.checks["completedWithoutFatalError"] = false }
                self.finish()
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, !self.finished else { return }
            self.checks["completedWithinTimeout"] = false; self.finish()
        }
    }
    var base: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    func pause(_ seconds: Double = 0.1) async { try? await Task.sleep(for: .seconds(seconds)) }
    func js(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
    func wait(_ view: WKWebView, _ expression: String, timeout: Double = 8) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await js(view, "return Boolean(\(expression));")) as? Bool == true { return true }
            await pause()
        }
        return false
    }
    func findPage(path: String, controller: WKWebExtensionController, timeout: Double = 8) async -> WKWebView? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let view = NSApp.windows.filter(\.isVisible).compactMap({ $0.contentView as? WKWebView }).first(where: {
                $0.configuration.webExtensionController === controller && $0.url?.path == path
            }) { return view }
            await pause()
        }
        return nil
    }
    func fixture() throws -> URL {
        let directory = work.appendingPathComponent("extension-source", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Production Host Fixture", "description": "Exercises Feather's exact production extension host with synthetic local pages.", "version": "1.0", "permissions": ["storage", "tabs"], "host_permissions": ["http://127.0.0.1/*", "file:///*"], "background": ["service_worker": "worker.js"], "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_end"]], "action": ["default_popup": "popup.html"], "options_ui": ["page": "options.html", "open_in_tab": true]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"))
        let files = [
            "worker.js": "chrome.runtime.onMessage.addListener((m,s,r)=>{if(m.kind==='ping')r({pong:true});});",
            "content.js": "document.documentElement.dataset.featherHostInjection=chrome.runtime.id;document.addEventListener('hostReadStorage',async()=>{document.documentElement.dataset.hostStoredMarker=(await chrome.storage.sync.get('marker')).marker||'absent';});",
            "ui.js": "document.body.dataset.fixtureReady='true';document.body.dataset.runtimeId=chrome.runtime.id;",
            "popup.html": "<!doctype html><title>Host fixture popup</title><h1>Popup fixture</h1><script src='ui.js'></script>",
            "options.html": "<!doctype html><title>Host fixture options</title><h1>Options fixture</h1><script src='ui.js'></script>"
        ]
        for (name, source) in files { try source.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return directory
    }
    func run() async throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let registry = work.appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: registry.appendingPathComponent("installed.json"))
        store = WebExtensionStore(directory: registry, bundledResourceURL: nil)
        let entry = try await store.install(from: fixture())
        checks["productionStoreImportsDisabled"] = !entry.enabled && store.entries.count == 1
        try store.setEnabled(true, id: entry.id)
        let manager = BrowserExtensionManager(store: store)
        state = BrowserState(manager: manager)
        let spaceA = Space(), spaceB = Space()
        let windowA = state.newWindow(space: spaceA)
        let tabA = state.openTab(base.appendingPathComponent("initial"), in: windowA)
        let viewA = tabA.webView!
        await manager.prepare(in: viewA)
        let controllerA = viewA.configuration.webExtensionController!
        checks["productionControllerLoadsImportedExtension"] = controllerA.extensionContexts.contains { $0.uniqueIdentifier == entry.id }
        if let context = controllerA.extensionContexts.first {
            checks["localFilePermissionDeniedEvenWhenRequested"] = !context.hasAccess(to: URL(fileURLWithPath: "/tmp/feather-extension-file-fixture.html"))
            let adapter = WebExtensionTabAdapter(tab: tabA, state: state)
            for (name, url) in [
                ("localFileNavigationRejected", URL(fileURLWithPath: "/tmp/feather-extension-file-fixture.html")),
                ("javascriptNavigationRejected", URL(string: "javascript:document.title='unexpected'")!),
                ("applicationNavigationRejected", URL(string: "mailto:fixture@example.invalid")!)
            ] {
                var rejected = false
                adapter.loadURL(url, for: context) { rejected = $0 != nil }
                checks[name] = rejected
            }
        }
        checks["trackBindPrepareInjectsContent"] = await wait(viewA, "document.documentElement.dataset.featherHostInjection === '\(entry.id)'")

        try await manager.performAction(id: entry.id, in: spaceA, dataStore: state.dataStore(spaceA), ephemeral: true)
        guard let popup = await findPage(path: "/popup.html", controller: controllerA) else {
            checks["productionPerformActionPresentsPopup"] = false
            observations["visiblePages"] = NSApp.windows.compactMap { ($0.contentView as? WKWebView)?.url?.absoluteString }
            return
        }
        checks["productionPerformActionPresentsPopup"] = await wait(popup, "document.body.dataset.fixtureReady==='true' && !!chrome.runtime")
        observations["popupConfiguration"] = ["sameController": popup.configuration.webExtensionController === controllerA, "nonpersistentDataStore": !popup.configuration.websiteDataStore.isPersistent]
        checks["productionPopupUsesCorrectController"] = popup.configuration.webExtensionController === controllerA
        checks["productionPopupUsesSpaceDataStore"] = popup.configuration.websiteDataStore === state.dataStore(spaceA)
        let popupAPI = try await js(popup, "const p=await chrome.runtime.sendMessage({kind:'ping'});await chrome.storage.sync.set({marker:'space-A'});localStorage.setItem('host-space-marker','space-A');const tabs=await chrome.tabs.query({});const activeTabs=await chrome.tabs.query({active:true,currentWindow:true});return {pong:p?.pong===true,tabs:tabs.map(t=>({id:t.id,url:t.url,active:t.active})),activeCurrentTabs:activeTabs.map(t=>({id:t.id,url:t.url,active:t.active}))};") as? [String: Any] ?? [:]
        observations["popupNativeAPI"] = popupAPI
        checks["popupWorkerMessaging"] = popupAPI["pong"] as? Bool == true
        checks["popupTabsQuerySeesBrowserTab"] = (popupAPI["tabs"] as? [[String: Any]] ?? []).contains { ($0["url"] as? String)?.contains("/initial") == true }
        let activeCurrentTabs = popupAPI["activeCurrentTabs"] as? [[String: Any]] ?? []
        checks["popupActiveCurrentTabRemainsOriginalWebsite"] = activeCurrentTabs.count == 1 && (activeCurrentTabs.first?["url"] as? String)?.contains("/initial") == true
        checks["actionPopupIsNotListedAsBrowserTab"] = !(popupAPI["tabs"] as? [[String: Any]] ?? []).contains { ($0["url"] as? String)?.contains("/popup.html") == true }

        _ = try await js(popup, "const tab=await chrome.tabs.create({url:'\(base.appendingPathComponent("created-by-popup").absoluteString)',active:true});return {id:tab.id};")
        await pause(0.2)
        let created = spaceA.allTabs.first { $0.url?.path == "/created-by-popup" }
        checks["popupTabsCreateUsesProductionDelegate"] = created != nil
        if let createdView = created?.webView {
            let injected = await wait(createdView, "!!document.documentElement.dataset.featherHostInjection")
            checks["createdTabGetsControllerAndContent"] = createdView.configuration.webExtensionController === controllerA && injected
        } else { checks["createdTabGetsControllerAndContent"] = false }

        try await manager.showOptions(id: entry.id, in: spaceA, dataStore: state.dataStore(spaceA), ephemeral: true)
        guard let optionsA = await findPage(path: "/options.html", controller: controllerA) else { checks["productionShowOptionsOpensPage"] = false; return }
        checks["productionShowOptionsOpensPage"] = await wait(optionsA, "document.body.dataset.fixtureReady==='true'")
        checks["productionOptionsUsesSpaceDataStore"] = optionsA.configuration.websiteDataStore === state.dataStore(spaceA)
        checks["optionsSharesPopupStorage"] = (try await js(optionsA, "return (await chrome.storage.sync.get('marker')).marker;")) as? String == "space-A"
        checks["optionsSharesPopupWebLocalStorage"] = (try await js(optionsA, "return localStorage.getItem('host-space-marker');")) as? String == "space-A"
        optionsA.window?.performClose(nil)
        await pause()
        _ = try await js(popup, "await chrome.runtime.openOptionsPage();return true;")
        checks["runtimeOpenOptionsUsesProductionDelegate"] = await findPage(path: "/options.html", controller: controllerA) != nil

        _ = try await js(popup, "return !!window.open('\(base.appendingPathComponent("window-open").absoluteString)','_blank');")
        await pause(0.4)
        let opened = spaceA.allTabs.first { $0.url?.path == "/window-open" }
        checks["popupWindowOpenUsesNormalWebsiteConfiguration"] = opened != nil && state.inheritedConfigurations == 0
        if let openedView = opened?.webView {
            checks["windowOpenDestinationLoads"] = await wait(openedView, "document.title==='Local host fixture'")
        }

        let windowB = state.newWindow(space: spaceB)
        let tabB = state.openTab(base.appendingPathComponent("space-b"), in: windowB)
        let viewB = tabB.webView!
        await manager.prepare(in: viewB)
        let controllerB = viewB.configuration.webExtensionController!
        checks["spacesUseDistinctProductionControllers"] = controllerB !== controllerA
        checks["secondSpaceGetsContentInjection"] = await wait(viewB, "!!document.documentElement.dataset.featherHostInjection")
        try await manager.showOptions(id: entry.id, in: spaceB, dataStore: state.dataStore(spaceB), ephemeral: true)
        guard let optionsB = await findPage(path: "/options.html", controller: controllerB) else { checks["secondSpaceOptionsOpens"] = false; return }
        _ = await wait(optionsB, "document.body.dataset.fixtureReady==='true'")
        checks["productionSpacesIsolatePreferences"] = (try await js(optionsB, "return (await chrome.storage.sync.get('marker')).marker===undefined;")) as? Bool == true
        checks["productionSpacesIsolateExtensionWebLocalStorage"] = (try await js(optionsB, "return localStorage.getItem('host-space-marker')===null;")) as? Bool == true
        _ = try await js(optionsB, "await chrome.storage.sync.set({marker:'space-B'});return true;")
        let optionsA2 = await findPage(path: "/options.html", controller: controllerA)
        if let optionsA2 { checks["secondSpaceWritePreservesFirstSpace"] = (try await js(optionsA2, "return (await chrome.storage.sync.get('marker')).marker;")) as? String == "space-A" }
        _ = try await js(viewB, "document.dispatchEvent(new Event('hostReadStorage'));return true;")
        checks["contentReadsItsOwnSpaceStorage"] = await wait(viewB, "document.documentElement.dataset.hostStoredMarker==='space-B'")

        try store.setEnabled(false, id: entry.id)
        await pause(0.2); await manager.prepare(in: viewA); await manager.prepare(in: viewB)
        checks["disableUnloadsBothProductionProfiles"] = controllerA.extensionContexts.isEmpty && controllerB.extensionContexts.isEmpty
        checks["disableClosesProductionPanels"] = !NSApp.windows.contains { window in
            guard window.isVisible, let view = window.contentView as? WKWebView else { return false }
            return view.url?.scheme == "webkit-extension"
        }
        viewA.load(URLRequest(url: base.appendingPathComponent("disabled")))
        _ = await wait(viewA, "location.pathname==='/disabled' && document.readyState==='complete'")
        checks["disabledExtensionDoesNotInjectAfterReload"] = (try await js(viewA, "return document.documentElement.dataset.featherHostInjection===undefined;")) as? Bool == true
        try store.setEnabled(true, id: entry.id)
        await pause(0.2); await manager.prepare(in: viewA)
        viewA.load(URLRequest(url: base.appendingPathComponent("reenabled")))
        checks["reenableRestoresInjection"] = await wait(viewA, "location.pathname==='/reenabled' && !!document.documentElement.dataset.featherHostInjection")
        observations["storeLastError"] = store.lastError ?? NSNull()
        observations["stubOpenedTabCount"] = spaceA.allTabs.count + spaceB.allTabs.count
        observations["productionFiles"] = ["Feather/Engine/BrowserExtensions.swift", "Feather/Engine/WebExtensionAdapters.swift", "Feather/Engine/WebExtensionStore.swift"]
    }
    func finish() {
        guard !finished else { return }; finished = true
        if let state { state.spaces.forEach { state.manager.forget($0) } }
        NSApp.windows.forEach { $0.orderOut(nil) }
        connections.forEach { $0.cancel() }; listener.cancel()
        let failed = checks.values.filter { !$0 }.count
        let report: [String: Any] = ["suite": "Production Feather extension host integration", "allPassed": failed == 0, "passedCount": checks.count - failed, "failedCount": failed, "checks": checks, "observations": observations, "elapsedSeconds": Date().timeIntervalSince(started), "scope": "Exact production manager, adapters, store. Minimal test-only browser models/factory seam. Private fixture app, isolated registry/storage, localhost HTTP synthetic extension. No Feather app or user session is opened."]
        do { try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: out, options: .atomic) }
        catch { fputs("Cannot write host smoke report: \(error)\n", stderr); exit(2) }
        print("Production extension host smoke: \(checks.count - failed) passed, \(failed) failed; \(out.path)")
        exit(failed == 0 ? 0 : 1)
    }
}

@main @MainActor enum HostMain {
    static func main() throws {
        let args = CommandLine.arguments
        guard let outputIndex = args.firstIndex(of: "--out"), outputIndex + 1 < args.count,
              let workIndex = args.firstIndex(of: "--work"), workIndex + 1 < args.count else {
            fputs("Expected --out REPORT.json --work PRIVATE_DIRECTORY\n", stderr); exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let harness = HostSmoke(out: URL(fileURLWithPath: args[outputIndex + 1]).standardizedFileURL,
                                work: URL(fileURLWithPath: args[workIndex + 1]).standardizedFileURL)
        try harness.start()
        withExtendedLifetime(harness) { app.run() }
    }
}
