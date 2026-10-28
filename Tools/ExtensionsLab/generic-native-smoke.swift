#!/usr/bin/env swift
// Exercises WebKit's public extension APIs with two local fixtures and no account data.
// Run: xcrun swift Tools/ExtensionsLab/generic-native-smoke.swift [--out PATH]
import AppKit
import Foundation
import Network
import WebKit

// WebKit returns WKNSError objects; casting its imported [Error] accessor can
// abort Swift on invalid manifests. KVC preserves the Objective-C NSError type.
func extensionErrors(_ object: NSObject) -> [String] {
    (object.value(forKey: "errors") as? [NSError] ?? []).map(\.localizedDescription)
}

@MainActor final class LabWindow: NSObject, WKWebExtensionWindow {
    var entries: [LabTab] = []
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { entries }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { entries.first }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { true }
}

@MainActor final class LabTab: NSObject, WKWebExtensionTab {
    let view: WKWebView
    unowned let owner: LabWindow
    init(_ view: WKWebView, owner: LabWindow) { self.view = view; self.owner = owner }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { view }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func isActive(for context: WKWebExtensionContext) -> Bool { owner.entries.first === self }
}

@MainActor final class LabProfile: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    let store = WKWebsiteDataStore.nonPersistent()
    let model = LabWindow()
    var contexts: [String: WKWebExtensionContext] = [:]
    var optionViews: [String: WKWebView] = [:]
    var popupViews: [String: WKWebView] = [:]
    var presented: [String] = []
    var openedOptions: [String] = []
    var windows: [NSWindow] = []

    override init() {
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = store
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = store
        configuration.webViewConfiguration = webConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    func add(_ resource: WKWebExtension, id: String) async throws -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: resource)
        context.uniqueIdentifier = id
        context.baseURL = URL(string: "webkit-extension://\(id)/")!
        context.hasAccessToPrivateData = true
        for permission in resource.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in resource.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        contexts[id] = context
        try controller.load(context)
        try await context.loadBackgroundContent()
        return context
    }

    func page(_ url: URL, context: WKWebExtensionContext? = nil, visible: Bool = false) -> WKWebView {
        let configuration = context?.webViewConfiguration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.webExtensionController = controller
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: configuration)
        let tab = LabTab(view, owner: model)
        model.entries.append(tab)
        controller.didOpenTab(tab)
        if model.entries.count == 1 { controller.didOpenWindow(model) }
        if visible {
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Feather extension compatibility fixture"
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        view.load(URLRequest(url: url))
        return view
    }

    func options(_ context: WKWebExtensionContext) -> WKWebView {
        if let existing = optionViews[context.uniqueIdentifier] { return existing }
        let view = page(context.optionsPageURL!, context: context)
        optionViews[context.uniqueIdentifier] = view
        return view
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [model] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { model }
    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        openedOptions.append(context.uniqueIdentifier)
        _ = options(context)
        completionHandler(nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        presented.append(context.uniqueIdentifier)
        if let view = action.popupWebView { popupViews[context.uniqueIdentifier] = view }
        completionHandler(nil)
    }

    func close() {
        for tab in model.entries { controller.didCloseTab(tab); tab.view.stopLoading() }
        model.entries.removeAll()
        for context in contexts.values where context.isLoaded { try? controller.unload(context) }
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        windows.removeAll()
        optionViews.removeAll()
        popupViews.removeAll()
        controller.delegate = nil
    }

    func eraseFixtureData() async {
        let types: Set<WKWebExtension.DataType> = [.local, .synchronized, .session]
        let records = await controller.dataRecords(ofTypes: types)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.removeData(ofTypes: types, from: records) { continuation.resume() }
        }
    }
}

@MainActor final class GenericNativeSmoke: NSObject {
    let output: URL
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("feather-extensions-lab-\(UUID().uuidString)")
    var listener: NWListener!
    var connections: [NWConnection] = []
    var profiles: [LabProfile] = []
    var checks: [String: Bool] = [:]
    var observations: [String: Any] = [:]
    var done = false
    let started = Date()

    init(output: URL) { self.output = output }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.connections.append(connection)
                connection.start(queue: .main)
                self?.receive(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.run() }
                catch { self.observations["fatalError"] = String(describing: error); self.checks["completedWithoutFatalError"] = false }
                for profile in self.profiles { profile.close(); await profile.eraseFixtureData() }
                self.finish()
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 100) { [weak self] in
            guard let self, !self.done else { return }
            self.checks["completedWithinTimeout"] = false
            self.finish()
        }
    }

    func receive(_ connection: NWConnection, previous: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var accumulated = previous
                if let data { accumulated.append(data) }
                if String(data: accumulated, encoding: .utf8)?.contains("\r\n\r\n") == true {
                    let body = Data("<!doctype html><html><head><title>Extensions Lab Fixture</title></head><body><h1>Local extension fixture</h1></body></html>".utf8)
                    let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: headers + body, completion: .contentProcessed { _ in connection.cancel() })
                } else if !complete && error == nil { self.receive(connection, previous: accumulated) }
                else { connection.cancel() }
            }
        }
    }

    func evaluate(_ view: WKWebView, _ code: String) async throws -> Any? {
        try await view.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .page)
    }
    func wait(_ view: WKWebView, _ expression: String, timeout: Double = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await evaluate(view, "return Boolean(\(expression));")) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return predicate()
    }

    func fixture(_ id: String, version: Int) throws -> URL {
        let directory = scratch.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let matches = ["http://127.0.0.1/*"]
        var manifest: [String: Any] = [
            "manifest_version": version, "name": "Feather \(id) fixture", "description": "Local synthetic compatibility test", "version": "1.0.0",
            "permissions": ["storage", "tabs"],
            "options_ui": ["page": "options.html", "open_in_tab": true],
            "content_scripts": [["matches": matches, "js": ["content.js"], "run_at": "document_end"]]
        ]
        manifest[version == 3 ? "action" : "browser_action"] = ["default_popup": "popup.html", "default_title": id]
        if version == 3 {
            manifest["background"] = ["service_worker": "background.js", "type": "module"]
            manifest["host_permissions"] = matches
        } else {
            manifest["background"] = ["scripts": ["background.js"], "persistent": false]
            manifest["permissions"] = ["storage", "tabs"] + matches
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"))
        let background = """
        const ready = (async () => {
            await chrome.storage.session.setAccessLevel({accessLevel:'TRUSTED_AND_UNTRUSTED_CONTEXTS'});
            await chrome.storage.session.set({workerID:'\(id)', backgroundKind:'\(version == 3 ? "service_worker_module" : "background_scripts")'});
        })();
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message?.type !== 'fixture-ping') return;
            ready.then(async () => {
                const local = await chrome.storage.local.get('marker');
                const session = await chrome.storage.session.get('workerID');
                sendResponse({extensionID:chrome.runtime.id,workerID:session.workerID,marker:local.marker||null});
            });
            return true;
        });
        """
        let content = """
        (async () => {
            try {
                const reply = await chrome.runtime.sendMessage({type:'fixture-ping'});
                const session = await chrome.storage.session.get('workerID');
                document.documentElement.setAttribute('data-\(id)', JSON.stringify({...reply,contentSessionID:session.workerID}));
            } catch (error) { document.documentElement.setAttribute('data-\(id)-error',String(error)); }
        })();
        """
        let pageScript = """
        document.documentElement.dataset.extensionID = chrome.runtime.id;
        document.documentElement.dataset.apiReady = String(!!chrome.storage?.local);
        document.body.textContent = 'Local extension fixture '+chrome.runtime.id;
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        try pageScript.write(to: directory.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        for name in ["options", "popup"] {
            let html = "<!doctype html><html><head><title>\(id) \(name)</title></head><body><script src='page.js'></script></body></html>"
            try html.write(to: directory.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
        }
        return directory
    }

    func run() async throws {
        let fixtureA = try fixture("fixture-a", version: 3)
        let fixtureB = try fixture("fixture-b", version: 2)
        let resourceA = try await WKWebExtension(resourceBaseURL: fixtureA)
        let resourceB = try await WKWebExtension(resourceBaseURL: fixtureB)
        let invalidFixture = try fixture("fixture-invalid", version: 3)
        let invalidManifestURL = invalidFixture.appendingPathComponent("manifest.json")
        var invalidManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: invalidManifestURL)) as! [String: Any]
        invalidManifest.removeValue(forKey: "description")
        try JSONSerialization.data(withJSONObject: invalidManifest).write(to: invalidManifestURL)
        let invalidResource = try await WKWebExtension(resourceBaseURL: invalidFixture)
        observations["invalidManifestErrors"] = extensionErrors(invalidResource)
        checks["invalidManifestErrorsCanBeInspectedSafely"] = !extensionErrors(invalidResource).isEmpty
        checks["mv3ManifestParses"] = extensionErrors(resourceA).isEmpty
        checks["mv2ManifestParses"] = extensionErrors(resourceB).isEmpty
        observations["manifestErrors"] = ["mv3": extensionErrors(resourceA), "mv2": extensionErrors(resourceB)]
        guard extensionErrors(resourceA).isEmpty && extensionErrors(resourceB).isEmpty else { return }
        let profileA = LabProfile(); profiles.append(profileA)
        let contextA = try await profileA.add(resourceA, id: "fixture-a")
        let contextB = try await profileA.add(resourceB, id: "fixture-b")
        checks["twoExtensionsLoadInOneController"] = profileA.controller.extensionContexts.count == 2 && contextA.isLoaded && contextB.isLoaded
        let optionsA = profileA.options(contextA)
        let optionsB = profileA.options(contextB)
        checks["mv3OptionsPageHasNativeAPI"] = await wait(optionsA, "document.documentElement.dataset.extensionID==='fixture-a' && document.documentElement.dataset.apiReady==='true'")
        checks["mv2OptionsPageHasNativeAPI"] = await wait(optionsB, "document.documentElement.dataset.extensionID==='fixture-b' && document.documentElement.dataset.apiReady==='true'")
        _ = try await evaluate(optionsA, "await chrome.storage.local.set({marker:'profile-A-extension-A'});await chrome.storage.sync.set({marker:'profile-A-extension-A'});await chrome.storage.session.set({profileMarker:'profile-A-extension-A'});return true;")
        _ = try await evaluate(optionsB, "await chrome.storage.local.set({marker:'profile-A-extension-B'});await chrome.storage.sync.set({marker:'profile-A-extension-B'});await chrome.storage.session.set({profileMarker:'profile-A-extension-B'});return true;")
        let valuesA = try await evaluate(optionsA, "return {local:(await chrome.storage.local.get('marker')).marker,sync:(await chrome.storage.sync.get('marker')).marker,session:(await chrome.storage.session.get('profileMarker')).profileMarker,kind:(await chrome.storage.session.get('backgroundKind')).backgroundKind};") as? [String: Any] ?? [:]
        let valuesB = try await evaluate(optionsB, "return {local:(await chrome.storage.local.get('marker')).marker,sync:(await chrome.storage.sync.get('marker')).marker,session:(await chrome.storage.session.get('profileMarker')).profileMarker,kind:(await chrome.storage.session.get('backgroundKind')).backgroundKind};") as? [String: Any] ?? [:]
        observations["profileAExtensionAStorage"] = valuesA
        observations["profileAExtensionBStorage"] = valuesB
        checks["storageIsolatesExtensions"] = ["local", "sync", "session"].allSatisfy { valuesA[$0] as? String == "profile-A-extension-A" && valuesB[$0] as? String == "profile-A-extension-B" }
        checks["mv3ModuleServiceWorkerRuns"] = valuesA["kind"] as? String == "service_worker_module"
        checks["mv2BackgroundScriptsRun"] = valuesB["kind"] as? String == "background_scripts"
        let url = URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/fixture")!
        let site = profileA.page(url, visible: true)
        checks["twoExtensionsInjectIntoSameTab"] = await wait(site, "document.documentElement.hasAttribute('data-fixture-a') && document.documentElement.hasAttribute('data-fixture-b')")
        let content = try await evaluate(site, "return {a:JSON.parse(document.documentElement.getAttribute('data-fixture-a')||'{}'),b:JSON.parse(document.documentElement.getAttribute('data-fixture-b')||'{}'),errors:[...document.documentElement.attributes].filter(a=>a.name.endsWith('-error')).map(a=>a.value)};") as? [String: Any] ?? [:]
        observations["sameTabContent"] = content
        let contentA = content["a"] as? [String: Any] ?? [:]
        let contentB = content["b"] as? [String: Any] ?? [:]
        checks["contentMessagesReachTheirOwnWorker"] = contentA["workerID"] as? String == "fixture-a" && contentB["workerID"] as? String == "fixture-b"
        checks["contentSessionStorageIsolatesExtensions"] = contentA["contentSessionID"] as? String == "fixture-a" && contentB["contentSessionID"] as? String == "fixture-b"
        checks["contentWorkerStorageIsolatesExtensions"] = contentA["marker"] as? String == "profile-A-extension-A" && contentB["marker"] as? String == "profile-A-extension-B"
        for context in [contextA, contextB] {
            let tab = profileA.model.entries.first { $0.view === site }
            context.performAction(for: tab)
            let presented = await eventually { profileA.presented.contains(context.uniqueIdentifier) }
            checks["\(context.uniqueIdentifier)ActionDelegatesPopup"] = presented
            if let popup = profileA.popupViews[context.uniqueIdentifier] {
                checks["\(context.uniqueIdentifier)PopupHasNativeAPI"] = await wait(popup, "document.documentElement.dataset.extensionID==='\(context.uniqueIdentifier)' && document.documentElement.dataset.apiReady==='true'")
            } else { checks["\(context.uniqueIdentifier)PopupHasNativeAPI"] = false }
        }
        _ = try await evaluate(optionsA, "await chrome.runtime.openOptionsPage();return true;")
        checks["runtimeOpenOptionsDelegatesToHost"] = await eventually { profileA.openedOptions.contains("fixture-a") }
        let profileB = LabProfile(); profiles.append(profileB)
        let otherA = try await profileB.add(resourceA, id: "fixture-a")
        let otherOptions = profileB.options(otherA)
        _ = await wait(otherOptions, "document.documentElement.dataset.apiReady==='true'")
        let isolated = try await evaluate(otherOptions, "return {localMissing:(await chrome.storage.local.get('marker')).marker===undefined,syncMissing:(await chrome.storage.sync.get('marker')).marker===undefined,sessionMissing:(await chrome.storage.session.get('profileMarker')).profileMarker===undefined};") as? [String: Any] ?? [:]
        observations["profileBStorage"] = isolated
        checks["storageIsolatesProfiles"] = ["localMissing", "syncMissing", "sessionMissing"].allSatisfy { isolated[$0] as? Bool == true }
        _ = try await evaluate(otherOptions, "await chrome.storage.local.set({marker:'profile-B-extension-A'});return true;")
        checks["profileBWriteDoesNotChangeProfileA"] = (try await evaluate(optionsA, "return (await chrome.storage.local.get('marker')).marker;")) as? String == "profile-A-extension-A"
        try profileA.controller.unload(contextB)
        checks["disableUnloadsOnlySelectedExtension"] = !contextB.isLoaded && contextA.isLoaded && profileA.controller.extensionContexts.count == 1
        site.load(URLRequest(url: url.appendingPathComponent("disabled")))
        checks["disabledExtensionStopsInjectingAfterReload"] = await wait(site, "document.documentElement.hasAttribute('data-fixture-a') && !document.documentElement.hasAttribute('data-fixture-b')")
        try profileA.controller.load(contextB)
        try await contextB.loadBackgroundContent()
        site.load(URLRequest(url: url.appendingPathComponent("enabled")))
        checks["reenabledExtensionInjectsAgain"] = await wait(site, "document.documentElement.hasAttribute('data-fixture-a') && document.documentElement.hasAttribute('data-fixture-b')")
        observations["runtimeErrors"] = ["mv3": extensionErrors(contextA), "mv2": extensionErrors(contextB)]
        checks["noNativeRuntimeErrors"] = extensionErrors(contextA).isEmpty && extensionErrors(contextB).isEmpty
    }

    func finish() {
        guard !done else { return }; done = true
        profiles.forEach { $0.close() }
        connections.forEach { $0.cancel() }
        listener.cancel()
        try? FileManager.default.removeItem(at: scratch)
        let failures = checks.values.filter { !$0 }.count
        let report: [String: Any] = ["suite": "Generic native WebKit extension compatibility", "runUTC": ISO8601DateFormatter().string(from: Date()), "environment": ProcessInfo.processInfo.operatingSystemVersionString, "checks": checks, "observations": observations, "passedCount": checks.count-failures, "failedCount": failures, "allPassed": failures == 0, "elapsedSeconds": Date().timeIntervalSince(started), "scope": "Two local MV2/MV3 fixtures, native workers/scripts, two contexts in one controller, same-tab injection, extension/profile local/sync/session storage isolation, action popups, options delegation, disable/re-enable. HTTP listener binds loopback only. No credentials, external downloads, or production profile storage."]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: output, options: .atomic)
            print("Generic native extension report: \(output.path); passed=\(checks.count-failures), failed=\(failures)")
        } catch { fputs("Could not write native extension report: \(error)\n", stderr); exit(2) }
        exit(failures == 0 ? 0 : 1)
    }
}

setbuf(stdout, nil)
let arguments = Array(CommandLine.arguments.dropFirst())
let defaultOutput = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("results-generic-native-smoke.json")
let output: URL
if arguments.isEmpty { output = defaultOutput }
else if arguments.count == 2 && arguments[0] == "--out" { output = URL(fileURLWithPath: arguments[1]) }
else { fputs("Usage: xcrun swift generic-native-smoke.swift [--out PATH]\n", stderr); exit(2) }
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let smoke = MainActor.assumeIsolated { GenericNativeSmoke(output: output) }
try MainActor.assumeIsolated { try smoke.start() }
application.run()
