import AppKit
import Darwin
import WebKit

/// An explicitly enabled, same-user bridge. No TCP ports or page-script handlers are exposed.
/// The transport owns no browser state; every operation hops to the main actor.
final class AgentBridge: NSObject {
    private unowned let state: BrowserState
    private var server: AgentSocketServer?
    private(set) var isRunning = false
    private(set) var socketPath: String?
    private var generation = 0
    // Reuse one world identity so element refs survive between snapshot and action calls.
    private let contentWorld = WKContentWorld.world(name: "FeatherAgent")

    init(state: BrowserState) { self.state = state }

    func start() throws {
        guard !isRunning else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.nesbes.Feather"
        let path = "/tmp/feather-agent-\(getuid())/\(bundleID).sock"
        generation += 1
        let startedGeneration = generation
        let server = try AgentSocketServer(path: path) { [weak self] data, reply in
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == startedGeneration else {
                    reply(Self.errorResponse(id: nil, code: "disabled", message: "Agent access is disabled."))
                    return
                }
                reply(await self.handle(data))
            }
        }
        self.server = server
        socketPath = path
        isRunning = true
        server.resume()
    }

    func stop() {
        generation += 1
        isRunning = false
        server?.stop()
        server = nil
        socketPath = nil
    }

    private func handle(_ data: Data) async -> Data {
        var id: Any?
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else {
                throw AgentError("invalid_request", "Expected a JSON object with a method.")
            }
            id = request["id"]
            guard id == nil || id is String || id is NSNumber else { throw AgentError("invalid_request", "Invalid request ID.") }
            guard request["params"] == nil || request["params"] is [String: Any] else {
                throw AgentError("invalid_params", "params must be an object.")
            }
            let params = request["params"] as? [String: Any] ?? [:]
            let result = try await perform(method, params)
            return Self.encode(["id": id ?? NSNull(), "result": result])
        } catch let error as AgentError {
            return Self.errorResponse(id: id, code: error.code, message: error.message)
        } catch {
            return Self.errorResponse(id: id, code: "operation_failed", message: error.localizedDescription)
        }
    }

    private func perform(_ method: String, _ params: [String: Any]) async throws -> Any {
        // A queued operation must not run after the user revokes access.
        guard isRunning else { throw AgentError("disabled", "Agent access is disabled.") }
        switch method {
        case "browser.info":
            return ["name": "Feather", "bundleID": Bundle.main.bundleIdentifier ?? "dev.nesbes.Feather",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1",
                    "protocolVersion": 1, "transport": "unix", "capabilities": ["tabs", "dom", "screenshot", "native-accessibility"]] as [String: Any]
        case "tabs.list":
            return ["tabs": state.allTabs.map(describe), "windows": state.windows.map { window in
                ["id": window.id.uuidString, "spaceID": window.space.id.uuidString,
                 "activeTabID": window.activeTab?.id.uuidString ?? NSNull()] as [String: Any]
            }]
        case "tabs.open":
            let url = try navigationURL(params)
            let tab = state.openTab(url, in: try targetWindow(params))
            return describe(tab)
        case "tabs.select":
            let tab = try targetTab(params)
            let window = try state.window(showing: tab) ?? targetWindow(params)
            state.select(tab, in: window)
            state.keyWindow = window
            if let native = tab.webView?.window { native.makeKeyAndOrderFront(nil) }
            return describe(tab)
        case "tabs.close":
            let tab = try targetTab(params)
            state.close(tab)
            return ["closed": tab.id.uuidString]
        case "page.navigate":
            let tab = try targetTab(params)
            let url = try navigationURL(params)
            state.lifecycle.load(url, fallbacks: [], in: tab)
            return describe(tab)
        case "page.back", "page.forward", "page.reload":
            let (tab, webView) = try targetWebView(params)
            switch method {
            case "page.back": webView.goBack()
            case "page.forward": webView.goForward()
            default: webView.reload()
            }
            return describe(tab)
        case "page.snapshot", "page.click", "page.fill", "page.select", "page.press", "page.scroll":
            let (tab, webView) = try targetWebView(params)
            if method == "page.snapshot" { try await waitUntilReady(tab) }
            var arguments = params
            arguments["operation"] = String(method.dropFirst(5))
            // callAsyncJavaScript passes arguments as values, never interpolated JavaScript.
            let result = try await webView.callAsyncJavaScript(AgentDOMScript.source, arguments: ["args": arguments],
                                                             in: nil, contentWorld: contentWorld)
            guard isRunning else { throw AgentError("disabled", "Agent access is disabled.") }
            guard var object = result as? [String: Any] else { throw AgentError("page_unavailable", "The page did not return a result.") }
            if let error = object["error"] as? String { throw AgentError("page_action_failed", error) }
            object["tabID"] = tab.id.uuidString
            return object
        case "page.screenshot":
            let (tab, webView) = try targetWebView(params)
            try await waitUntilReady(tab)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            let image = try await webView.takeSnapshot(configuration: configuration)
            guard isRunning else { throw AgentError("disabled", "Agent access is disabled.") }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw AgentError("screenshot_failed", "Could not encode the screenshot.")
            }
            return ["tabID": tab.id.uuidString, "mimeType": "image/png", "data": png.base64EncodedString()]
        default:
            throw AgentError("unknown_method", "Unknown method: \(method)")
        }
    }

    private func describe(_ tab: Tab) -> [String: Any] {
        let window = state.window(showing: tab)
        return ["id": tab.id.uuidString, "title": tab.displayTitle, "url": tab.url?.absoluteString ?? "about:blank",
                "spaceID": state.space(of: tab)?.id.uuidString ?? "", "space": state.space(of: tab)?.name ?? "",
                "windowID": window?.id.uuidString ?? NSNull(), "active": window?.activeTab === tab,
                "loading": tab.isLoading, "sleeping": !tab.isLive]
    }

    private func targetWindow(_ params: [String: Any]) throws -> WindowState {
        if let raw = params["windowID"] {
            guard let text = raw as? String, let id = UUID(uuidString: text),
                  let window = state.windows.first(where: { $0.id == id }) else {
                throw AgentError("invalid_window", "No window matches windowID.")
            }
            return window
        }
        guard let window = state.keyWindow ?? state.windows.first else { throw AgentError("no_window", "Open a Feather window first.") }
        return window
    }

    private func targetTab(_ params: [String: Any]) throws -> Tab {
        if let raw = params["tabID"] {
            guard let text = raw as? String, let id = UUID(uuidString: text), let tab = state.tab(id: id) else {
                throw AgentError("invalid_tab", "No tab matches tabID.")
            }
            return tab
        }
        guard let tab = try targetWindow(params).activeTab else { throw AgentError("no_tab", "Open a tab first.") }
        return tab
    }

    private func targetWebView(_ params: [String: Any]) throws -> (Tab, WKWebView) {
        let tab = try targetTab(params)
        // Agent work should be visible, and must not be immediately discarded by the sleeping policy.
        if state.window(showing: tab) == nil { state.select(tab, in: try targetWindow(params)) }
        state.lifecycle.ensureLive(tab)
        guard let view = tab.webView else { throw AgentError("page_unavailable", "The tab could not be loaded.") }
        return (tab, view)
    }

    private func navigationURL(_ params: [String: Any]) throws -> URL {
        guard let text = params["url"] as? String, text.count <= 16_384, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil || text == "about:blank" else {
            throw AgentError("invalid_url", "Use a complete http or https URL, or about:blank.")
        }
        return url
    }

    private func waitUntilReady(_ tab: Tab) async throws {
        let deadline = Date.now.addingTimeInterval(8)
        while tab.isLoading && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            guard isRunning else { throw AgentError("disabled", "Agent access is disabled.") }
        }
        if tab.isLoading { throw AgentError("page_loading", "The page is still loading; retry the operation.") }
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func errorResponse(id: Any?, code: String, message: String) -> Data {
        encode(["id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }
}

private struct AgentError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// Isolated from MainActor so a slow or malformed client cannot block the browser UI.
private nonisolated final class AgentSocketServer: @unchecked Sendable {
    private let path: String
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let handler: @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var clients: Set<Int32> = []
    private var device: dev_t = 0
    private var inode: ino_t = 0

    init(path: String, handler: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        self.path = path
        self.handler = handler
        let folder = (path as NSString).deletingLastPathComponent
        if mkdir(folder, 0o700) != 0 && errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var folderInfo = stat()
        guard lstat(folder, &folderInfo) == 0, folderInfo.st_uid == getuid(),
              folderInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), folderInfo.st_mode & 0o077 == 0 else {
            throw AgentError("unsafe_directory", "Agent socket directory must be owned by you and private (0700).")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentError("invalid_path", "Agent socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        var oldInfo = stat()
        if lstat(path, &oldInfo) == 0 {
            guard oldInfo.st_uid == getuid(), oldInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
                throw AgentError("unsafe_socket", "The agent socket path belongs to another file.")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(probe) }
            let connected = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected != 0 else { throw AgentError("already_running", "Another Feather instance already has agent access enabled.") }
            guard errno == ECONNREFUSED || errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            unlink(path)
        }
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        descriptor = socketDescriptor
        guard socketDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(descriptor); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let error = errno; close(descriptor); unlink(path); throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        var info = stat()
        if lstat(path, &info) == 0 { device = info.st_dev; inode = info.st_ino }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
    }

    func resume() { source.resume() }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        // Keep shutdown synchronized with remove+close: descriptor numbers can be reused immediately.
        for client in clients { shutdown(client, SHUT_RDWR) }
        lock.unlock()
        source.cancel()
        // Do not remove another instance's replacement socket.
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == device, info.st_ino == inode { unlink(path) }
    }

    private func acceptConnections() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            // Darwin inherits the listener's nonblocking flag. Clients use bounded blocking I/O.
            let flags = fcntl(client, F_GETFL, 0)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { close(client); continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            lock.lock()
            let reject = stopped || clients.count >= 8
            if !reject { clients.insert(client) }
            lock.unlock()
            if reject { close(client); continue }
            DispatchQueue.global(qos: .utility).async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { lock.lock(); clients.remove(client); close(client); lock.unlock() }
        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var request = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while request.count <= 65_536 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            request.append(contentsOf: buffer.prefix(count))
            if let newline = request.firstIndex(of: 10) {
                guard newline <= 65_536 else { return }
                let completed = DispatchSemaphore(value: 0)
                // Reply writes happen on this background queue; the callback never blocks MainActor.
                let reply = AgentSocketReply()
                handler(request.prefix(upTo: newline)) { data in reply.set(data); completed.signal() }
                guard completed.wait(timeout: .now() + 12) == .success, let data = reply.get() else { return }
                var response = data
                response.append(10)
                response.withUnsafeBytes { bytes in
                    var written = 0
                    while written < bytes.count {
                        let count = send(client, bytes.baseAddress!.advanced(by: written), bytes.count - written, 0)
                        guard count > 0 else { return }
                        written += count
                    }
                }
                return
            }
        }
    }
}

private nonisolated final class AgentSocketReply: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ data: Data) { lock.lock(); self.data = data; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}
