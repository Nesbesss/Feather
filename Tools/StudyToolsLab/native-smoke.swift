#!/usr/bin/env swift
// Native WebKit extension smoke test. Uses fresh extension storage and synthetic
// Magister HTTP traffic through a loopback SOCKS proxy; no school account is used.
// xcrun swift Tools/StudyToolsLab/native-smoke.swift --extension PATH --out REPORT.json
import AppKit
import Foundation
import Network
import WebKit

struct SmokeOptions {
    let source: URL
    let output: URL
    static func parse() throws -> SmokeOptions {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var source = directory.appendingPathComponent("../../Feather/Resources/StudyTools").standardizedFileURL
        var output = directory.appendingPathComponent("results-native-smoke.json")
        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < args.count {
            guard index + 1 < args.count, ["--extension", "--out"].contains(args[index]) else {
                throw NSError(domain: "StudyToolsLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected --extension DIRECTORY and/or --out REPORT.json"])
            }
            if args[index] == "--extension" { source = URL(fileURLWithPath: args[index + 1]).standardizedFileURL }
            else { output = URL(fileURLWithPath: args[index + 1]).standardizedFileURL }
            index += 2
        }
        return SmokeOptions(source: source, output: output)
    }
}

@MainActor final class FixtureWindow: NSObject, WKWebExtensionWindow {
    var entries: [FixtureTab] = []
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { entries }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { entries.last }
}

@MainActor final class FixtureTab: NSObject, WKWebExtensionTab {
    let view: WKWebView
    unowned let owner: FixtureWindow
    init(_ view: WKWebView, owner: FixtureWindow) { self.view = view; self.owner = owner }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { view }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func isActive(for context: WKWebExtensionContext) -> Bool { owner.entries.last === self }
}

@MainActor final class SmokeRuntime: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    let context: WKWebExtensionContext
    let model = FixtureWindow()
    let store: WKWebsiteDataStore
    var createdURLs: [String] = []
    var views: [WKWebView] = []
    var display: NSWindow?

    init(extension resource: WKWebExtension, storageID: UUID, proxyPort: NWEndpoint.Port) throws {
        store = .nonPersistent()
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: proxyPort))
        proxy.matchDomains = ["fixture.magister.net"]
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
        let config = WKWebExtensionController.Configuration(identifier: storageID)
        config.defaultWebsiteDataStore = store
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = store
        config.webViewConfiguration = webConfig
        controller = WKWebExtensionController(configuration: config)
        context = WKWebExtensionContext(for: resource)
        context.uniqueIdentifier = "study-tools-native-smoke"
        context.baseURL = URL(string: "webkit-extension://study-tools-native-smoke/")!
        context.isInspectable = true
        // The smoke suite intentionally uses non-persistent website stores.
        context.hasAccessToPrivateData = true
        for permission in resource.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in resource.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        super.init()
        controller.delegate = self
        try controller.load(context)
        controller.didOpenWindow(model)
    }

    func create(_ url: URL, extensionPage: Bool = false, visible: Bool = false) -> WKWebView {
        let config = extensionPage ? (context.webViewConfiguration ?? WKWebViewConfiguration()) : WKWebViewConfiguration()
        config.websiteDataStore = store
        config.webExtensionController = controller
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1040, height: 820), configuration: config)
        view.isInspectable = true
        let tab = FixtureTab(view, owner: model)
        model.entries.append(tab)
        views.append(view)
        controller.didOpenTab(tab)
        controller.didActivateTab(tab)
        if visible {
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Study Tools native compatibility check"
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            display = window
        }
        view.load(URLRequest(url: url))
        return view
    }

    func options(visible: Bool = false) -> WKWebView {
        create(URL(string: "popup/dist/index.html?type=options", relativeTo: context.baseURL)!.absoluteURL, extensionPage: true, visible: visible)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [model] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { model }
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let url = configuration.url else { completionHandler(nil, NSError(domain: "StudyToolsLab", code: 2)); return }
        createdURLs.append(url.absoluteString)
        _ = create(url, extensionPage: url.scheme == context.baseURL.scheme)
        completionHandler(model.entries.last, nil)
    }

    func close() {
        for tab in model.entries { controller.didCloseTab(tab); tab.view.stopLoading() }
        model.entries.removeAll()
        views.removeAll()
        display?.orderOut(nil)
        display?.contentView = nil
        display = nil
        try? controller.unload(context)
        controller.delegate = nil
    }
}

@MainActor final class NativeSmoke: NSObject {
    let options: SmokeOptions
    var listener: NWListener!
    var connections: [NWConnection] = []
    var checks: [String: Bool] = [:]
    var observations: [String: Any] = [:]
    var requests: [[String: Any]] = []
    var active: [SmokeRuntime] = []
    var scratch: URL!
    var finished = false
    let started = Date()

    init(options: SmokeOptions) { self.options = options }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.connections.append(connection)
                connection.start(queue: .main)
                self?.receive(connection, stage: 0)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.run() }
                catch { self.observations["fatalError"] = String(describing: error); self.checks["completedWithoutFatalError"] = false }
                self.finish()
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, !self.finished else { return }
            self.observations["fatalError"] = "Native smoke timed out after 120 seconds"
            self.checks["completedWithinTimeout"] = false
            self.finish()
        }
    }

    // Minimal no-auth SOCKS5 responder, restricted by the data-store proxy config
    // to fixture.magister.net. It serves synthetic HTTP instead of forwarding.
    func receive(_ connection: NWConnection, stage: Int, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var bytes = buffered
                if let data { bytes.append(data) }
                if stage == 0 {
                    guard bytes.count >= 2 else { self.receive(connection, stage: stage, buffered: bytes); return }
                    let size = 2 + Int(bytes[1])
                    guard bytes.count >= size else { self.receive(connection, stage: stage, buffered: bytes); return }
                    connection.send(content: Data([5, 0]), completion: .contentProcessed { _ in })
                    self.receive(connection, stage: 1, buffered: Data(bytes.dropFirst(size)))
                } else if stage == 1 {
                    guard bytes.count >= 5 else { self.receive(connection, stage: stage, buffered: bytes); return }
                    let size = bytes[3] == 3 ? 7 + Int(bytes[4]) : bytes[3] == 1 ? 10 : 22
                    guard bytes.count >= size else { self.receive(connection, stage: stage, buffered: bytes); return }
                    connection.send(content: Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]), completion: .contentProcessed { _ in })
                    self.receive(connection, stage: 2, buffered: Data(bytes.dropFirst(size)))
                } else if let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") {
                    self.respond(connection, request: request)
                } else if !complete && error == nil { self.receive(connection, stage: stage, buffered: bytes) }
                else { connection.cancel() }
            }
        }
    }

    func respond(_ connection: NWConnection, request: String) {
        let first = request.components(separatedBy: "\r\n").first ?? ""
        let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let authorization = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("authorization:") } ?? ""
        requests.append(["path": path, "fakeAuthorizationReceived": authorization.contains("FEATHER_FAKE_NATIVE_TOKEN")])
        let isAPI = path.contains("/api/")
        let body = isAPI ? "{}" : "<!doctype html><html><head><title>Synthetic Magister fixture</title></head><body><main class='app-container'><h1>Magister test fixture</h1><p>No school account or real token is used.</p></main></body></html>"
        let content = Data(body.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(isAPI ? "application/json" : "text/html"); charset=utf-8\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + content, completion: .contentProcessed { _ in connection.cancel() })
    }

    func pause(_ seconds: Double = 0.2) async { try? await Task.sleep(for: .seconds(seconds)) }
    func js(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
    func wait(_ view: WKWebView, _ expression: String, seconds: Double = 12) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if (try? await js(view, "return Boolean(\(expression));")) as? Bool == true { return true }
            await pause()
        }
        return false
    }

    func make(_ resource: WKWebExtension, id: UUID = UUID()) throws -> SmokeRuntime {
        let runtime = try SmokeRuntime(extension: resource, storageID: id, proxyPort: listener.port!)
        active.append(runtime)
        return runtime
    }

    func run() async throws {
        observations["source"] = options.source.path
        let original = try await WKWebExtension(resourceBaseURL: options.source)
        observations["manifestVersion"] = original.manifestVersion
        observations["version"] = original.manifest["version"]
        observations["originalManifestErrors"] = original.errors.map(\.localizedDescription)
        checks["realManifestParses"] = original.errors.isEmpty
        let identityA = UUID()
        var runtimeA: SmokeRuntime? = try make(original, id: identityA)
        checks["realManifestLoads"] = runtimeA?.context.isLoaded == true
        try await runtimeA!.context.loadBackgroundContent()
        let pageA = runtimeA!.options(visible: true)
        checks["realOptionsVueMounts"] = await wait(pageA, "document.querySelector('#app')?.children.length > 0 && document.body.innerText.length > 100")
        checks["realOptionsStylesLoad"] = await wait(pageA, "document.getElementById('app-wrapper') && getComputedStyle(document.getElementById('app-wrapper')).display==='grid'", seconds: 20)
        observations["optionsDOM"] = try await js(pageA, "return {title:document.title,appChildren:document.querySelector('#app')?.children.length,bodyLength:document.body.innerText.length,hasChromeStorage:!!globalThis.chrome?.storage,font:getComputedStyle(document.body).fontFamily,stylesheets:[...document.styleSheets].map(s=>({url:s.href,disabled:s.disabled,rules:(()=>{try{return s.cssRules.length}catch(e){return String(e)}})()}))};")
        checks["serviceWorkerDefaultsAvailable"] = await wait(pageA, "globalThis.chrome?.storage")
        let storageA = try await js(pageA, "await chrome.storage.sync.set({'feather-native-marker':'space-A','ptheme':'dark,207,95,55'}); const s=await chrome.storage.sync.get(); return {marker:s['feather-native-marker'],defaultCount:Object.keys(s).length,theme:s.ptheme};") as? [String: Any] ?? [:]
        observations["spaceAStorage"] = storageA
        checks["syncStorageRoundTrips"] = storageA["marker"] as? String == "space-A"
        checks["serviceWorkerInitializesDefaults"] = (storageA["defaultCount"] as? Int ?? 0) > 10

        let screenshot = options.output.deletingPathExtension().appendingPathExtension("png")
        if let image = try? await pageA.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(at: screenshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: screenshot)
            observations["optionsScreenshot"] = screenshot.path
        }

        let realFixture = runtimeA!.create(URL(string: "http://fixture.magister.net/fixture")!)
        checks["actualMagisterHostServedOnLoopback"] = await wait(realFixture, "document.title === 'Synthetic Magister fixture'")
        checks["realContentScriptAppliesTheme"] = await wait(realFixture, "document.getElementById('study-tools-vars') && getComputedStyle(document.documentElement).getPropertyValue('--st-background-primary').trim()==='#121212'")
        observations["contentTheme"] = try await js(realFixture, "return {style:!!document.getElementById('study-tools-vars'),background:getComputedStyle(document.documentElement).getPropertyValue('--st-background-primary').trim(),font:getComputedStyle(document.documentElement).getPropertyValue('--st-font-family-primary').trim()};")
        _ = try await js(realFixture, "await fetch('/api/personen/12345/aanmeldingen/1/cijfers/extracijferkolominfo/1',{headers:{Authorization:'Bearer FEATHER_FAKE_NATIVE_TOKEN'}}); return true;")
        await pause(0.6)
        let credentialState = try await js(pageA, "const a=await chrome.storage.sync.get('user-id'),b=await chrome.storage.session.get(['token','token-date']);return {userID:a['user-id'],capturedFakeToken:b.token==='Bearer FEATHER_FAKE_NATIVE_TOKEN',hasTokenDate:typeof b['token-date']==='number'};") as? [String: Any] ?? [:]
        observations["realWebRequestCredentials"] = credentialState
        checks["realWebRequestCapturesAuthorization"] = credentialState["capturedFakeToken"] as? Bool == true
        checks["realWebRequestCapturesUserID"] = credentialState["userID"] as? String == "12345"
        checks["realWebRequestCapturesTokenDate"] = credentialState["hasTokenDate"] as? Bool == true

        _ = try await js(pageA, "chrome.runtime.sendMessage({action:'openOptions',data:'type=options&tab=login'}); return true;")
        await pause(0.6)
        observations["workerOpenedURLs"] = runtimeA!.createdURLs
        checks["realWorkerOpenOptionsDelegatesToHost"] = runtimeA!.createdURLs.contains { $0.contains("popup/dist/index.html?") && $0.contains("tab=login") }

        let runtimeB = try make(original)
        let pageB = runtimeB.options()
        _ = await wait(pageB, "globalThis.chrome?.storage")
        let isolated = try await js(pageB, "const s=await chrome.storage.sync.get('feather-native-marker'),t=await chrome.storage.session.get('token');return {markerAbsent:s['feather-native-marker']===undefined,tokenAbsent:t.token===undefined};") as? [String: Any] ?? [:]
        observations["spaceBStorage"] = isolated
        checks["separateControllerStorageIsolatesPreferences"] = isolated["markerAbsent"] as? Bool == true
        checks["separateControllerStorageIsolatesSessionToken"] = isolated["tokenAbsent"] as? Bool == true
        _ = try await js(pageB, "await chrome.storage.sync.set({'feather-native-marker':'space-B'}); return true;")
        checks["separateControllerWriteDoesNotChangeSpaceA"] = (try await js(pageA, "return (await chrome.storage.sync.get('feather-native-marker'))['feather-native-marker'];")) as? String == "space-A"
        runtimeB.close()
        runtimeA!.close()
        active.removeAll()
        runtimeA = nil
        await pause(0.8)

        let restored = try make(original, id: identityA)
        let restoredPage = restored.options()
        _ = await wait(restoredPage, "globalThis.chrome?.storage")
        let persisted = try await js(restoredPage, "const s=await chrome.storage.sync.get('feather-native-marker');return {marker:s['feather-native-marker']||null};") as? [String: Any] ?? [:]
        observations["restoredSpaceAStorage"] = persisted
        checks["controllerIdentityPersistsPreferences"] = persisted["marker"] as? String == "space-A"
        restored.close()
        active.removeAll()

        try await contentSessionProbe()
        observations["syntheticRequests"] = requests
    }

    func contentSessionProbe() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("feather-study-tools-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: options.source, to: scratch)
        let manifestURL = scratch.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var scripts = manifest["content_scripts"] as! [[String: Any]]
        scripts.append(["matches": ["http://fixture.magister.net/*"], "js": ["native-smoke-diagnostic.js"], "run_at": "document_end"])
        manifest["content_scripts"] = scripts
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL)
        let diagnostic = #"""
        document.addEventListener('nativeSmokeCheck', async () => {
            try {
                const s=await chrome.storage.session.get('token');
                const p=chrome.runtime.getURL('manifest.json');
                document.documentElement.dataset.nativeSmokeResult=JSON.stringify({contentSessionReadable:s.token==='Bearer FEATHER_FAKE_NATIVE_TOKEN',runtimeURL:p});
            } catch(e) { document.documentElement.dataset.nativeSmokeResult=JSON.stringify({error:String(e)}); }
        });
        """#
        try diagnostic.write(to: scratch.appendingPathComponent("native-smoke-diagnostic.js"), atomically: true, encoding: .utf8)
        observations["contentSessionInstrumentation"] = "Temporary copy appends one diagnostic-only content script in manifest; production scripts and Magister match patterns are unchanged. Diagnostic reports only whether a known fake token was read and the native runtime resource URL."
        let resource = try await WKWebExtension(resourceBaseURL: scratch)
        let runtime = try make(resource)
        try await runtime.context.loadBackgroundContent()
        let page = runtime.options()
        _ = await wait(page, "globalThis.chrome?.storage")
        _ = try await js(page, "await chrome.storage.session.set({token:'Bearer FEATHER_FAKE_NATIVE_TOKEN'});return true;")
        let fixture = runtime.create(URL(string: "http://fixture.magister.net/fixture")!)
        _ = await wait(fixture, "document.title === 'Synthetic Magister fixture'")
        await pause(0.3)
        _ = try await js(fixture, "document.dispatchEvent(new Event('nativeSmokeCheck'));return true;")
        checks["contentDiagnosticReturns"] = await wait(fixture, "document.documentElement.dataset.nativeSmokeResult")
        let result = try await js(fixture, "return JSON.parse(document.documentElement.dataset.nativeSmokeResult||'{}');") as? [String: Any] ?? [:]
        observations["contentSessionAPI"] = result
        checks["sessionAccessLevelAllowsContentScripts"] = result["contentSessionReadable"] as? Bool == true
        checks["nativeRuntimeResourceAPIInContentScript"] = (result["runtimeURL"] as? String)?.hasPrefix("webkit-extension://study-tools-native-smoke/") == true
        runtime.close()
        active.removeAll()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        active.forEach { $0.close() }
        connections.forEach { $0.cancel() }
        listener.cancel()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        let failures = checks.values.filter { !$0 }.count
        let report: [String: Any] = ["suite": "Native Study Tools WKWebExtension smoke", "runUTC": ISO8601DateFormatter().string(from: Date()), "environment": ProcessInfo.processInfo.operatingSystemVersionString, "checks": checks, "observations": observations, "passedCount": checks.count - failures, "failedCount": failures, "allPassed": failures == 0, "elapsedSeconds": Date().timeIntervalSince(started), "scope": "Real Study Tools native manifest, module service worker, Vue options, sync/session storage, content CSS/theme, webRequest header capture, worker tab delegation. Synthetic Magister host uses isolated data-store loopback SOCKS proxy. No real school data, cookies, or authentication."]
        do {
            try FileManager.default.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: options.output, options: .atomic)
            print("Native Study Tools report: \(options.output.path); passed=\(checks.count - failures), failed=\(failures)")
        } catch { fputs("Cannot write report: \(error)\n", stderr); exit(2) }
        exit(failures == 0 ? 0 : 1)
    }
}

let smokeOptions = try SmokeOptions.parse()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let smoke = MainActor.assumeIsolated { NativeSmoke(options: smokeOptions) }
try MainActor.assumeIsolated { try smoke.start() }
app.run()
