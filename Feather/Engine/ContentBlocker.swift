import CryptoKit
import Foundation
import WebKit
import os

/// Loads the bundled ad/tracker rule lists into WebKit. Lists are compiled once
/// and cached by `WKContentRuleListStore` (memory-mapped and shared by all
/// WebContent processes), keyed by a hash of their JSON.
final class ContentBlocker {
    enum PreparationState: Equatable {
        case idle, loading, ready
        /// Preparation completed; successfully compiled lists remain usable.
        case failed([String])
    }

    private static let bundledLists = ["network", "cosmetic"]
    private let log = Logger(subsystem: "dev.nesbes.Feather", category: "ContentBlocker")
    private let settings: AppSettings
    private(set) var ruleLists: [WKContentRuleList] = []
    /// Controllers and whether they currently have the lists installed.
    private var controllers: [ObjectIdentifier: (controller: WeakRef<WKUserContentController>, blocking: Bool)] = [:]
    private(set) var ruleCount = 0
    private(set) var preparationState: PreparationState = .idle
    private var preparation: Task<Void, Never>?
    var onReady: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard preparation == nil else { return }
        preparationState = .loading
        preparation = Task {
            guard let store = WKContentRuleListStore.default() else {
                preparationState = .failed(["WebKit content rule store is unavailable"])
                log.error("WebKit content rule store is unavailable")
                onReady?()
                return
            }
            var lists: [WKContentRuleList] = []
            var wanted: Set<String> = []
            var errors: [String] = []
            for name in Self.bundledLists {
                guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Blocklist"),
                      let data = try? Data(contentsOf: url) else {
                    let error = "Missing bundled Blocklist/\(name).json"
                    errors.append(error)
                    log.error("\(error, privacy: .public)")
                    continue
                }
                let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
                let identifier = "feather.\(name).\(digest)"
                wanted.insert(identifier)
                if let list = await store.lookUp(identifier) {
                    lists.append(list)
                    continue
                }
                let started = Date()
                do {
                    if let list = try await store.compile(identifier, json: String(decoding: data, as: UTF8.self)) {
                        lists.append(list)
                        log.info("Compiled \(name) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
                    } else {
                        errors.append("WebKit returned no compiled \(name) rule list")
                    }
                } catch {
                    errors.append("\(name): \(error.localizedDescription)")
                    log.error("Rule list \(name) failed to compile: \(error.localizedDescription)")
                }
            }
            // Drop lists left over from older app versions.
            for identifier in await store.availableIdentifiers() where identifier.hasPrefix("feather.") && !wanted.contains(identifier) {
                await store.remove(identifier)
            }
            ruleLists = lists
            for entry in controllers.values where entry.blocking {
                guard let controller = entry.controller.value else { continue }
                lists.forEach(controller.add)
            }
            preparationState = errors.isEmpty ? .ready : .failed(errors)
            onReady?()
        }
    }

    /// Coalesces startup and concurrent navigations. A compiler error completes this
    /// wait with an explicit failed state rather than leaving navigation pending.
    func prepare() async {
        start()
        await preparation?.value
    }

    /// Registers a web view's controller, blocking by default.
    func install(into controller: WKUserContentController) {
        controllers = controllers.filter { $0.value.controller.value != nil }
        let blocking = settings.blockContent
        controllers[ObjectIdentifier(controller)] = (WeakRef(controller), blocking)
        if blocking { ruleLists.forEach(controller.add) }
    }

    /// Turns blocking on or off for one web view, e.g. for an allowlisted site.
    func setBlocking(_ blocking: Bool, for controller: WKUserContentController) {
        let key = ObjectIdentifier(controller)
        guard controllers[key]?.blocking != blocking else { return }
        controllers[key] = (WeakRef(controller), blocking)
        if blocking {
            ruleLists.forEach(controller.add)
        } else {
            ruleLists.forEach(controller.remove)
        }
    }

    func shouldBlock(host: String?) -> Bool {
        settings.blockContent && !YouTubeBlockingPolicy.isAllowlisted(host, hosts: settings.allowlistedHosts)
    }
}

final class WeakRef<T: AnyObject> {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

// Completion-handler APIs wrapped for async use.
private extension WKContentRuleListStore {
    func availableIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
    }

    func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list) }
        }
    }

    func compile(_ identifier: String, json: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list) }
            }
        }
    }

    func remove(_ identifier: String) async {
        await withCheckedContinuation { continuation in
            removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }
}
