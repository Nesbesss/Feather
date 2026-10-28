import AppKit
import CryptoKit
import CoreFoundation
import Darwin
import WebKit

/// `Feather -BenchmarkURLs urls.txt -BenchmarkReport out.json [-BenchmarkInterval 6] [-BenchmarkSettle 45]`
/// Add `-BenchmarkYouTube YES` for passive YouTube playback observations.
/// Opens each URL in a new foreground tab, lets the sleep policy run, samples
/// total memory every 2 s, writes a JSON report, and quits. Runs with a fresh,
/// unsaved session. Pick the profile with `-FeatherProfile lean|balanced|unlimited`.
final class BenchmarkRunner {
    /// Explicit local experiment only; validated before BrowserState is created.
    struct MatchedMemoryRequest {
        let runID: String
        let root: URL
        let urls: [URL]
        let probeSource: String
        let probeSHA256: String
        let configSHA256: String
        let readyReport: URL
        let finalReport: URL
        let sampleWindowReceipt: URL
        let operatorStart: URL?
        let operatorReady: URL?

        /// A missing file's full URL can retain a different /private/tmp alias
        /// from its existing root. Resolve the existing parent,then append its leaf.
        static func freshOwnedOutput(_ raw: String, root: URL, excludedInputs: [URL],
                                     canonical: (String) -> URL) throws -> URL {
            func rejected() -> NSError {
                NSError(domain: "Feather.MatchedRetainedMemory", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Matched-memory receipts must be fresh owned file paths with existing parents."])
            }
            guard raw.hasPrefix("/") else { throw rejected() }
            let unresolved = URL(fileURLWithPath: raw).standardizedFileURL
            let parent = unresolved.deletingLastPathComponent()
            var directory: ObjCBool = false
            guard !unresolved.hasDirectoryPath, !unresolved.lastPathComponent.isEmpty,
                  FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
                throw rejected()
            }
            let resolvedParent = canonical(parent.path)
            let result = resolvedParent.appendingPathComponent(unresolved.lastPathComponent, isDirectory: false)
            let excludedPaths = excludedInputs.map {
                canonical($0.deletingLastPathComponent().path).appendingPathComponent($0.lastPathComponent, isDirectory: false).path
            }
            guard result.path.hasPrefix(root.path + "/"), !excludedPaths.contains(result.path),
                  !FileManager.default.fileExists(atPath: raw) else { throw rejected() }
            // Reject existing and dangling leaf symlinks as well as ordinary files.
            var leaf = stat()
            let status = unresolved.path.withCString { lstat($0, &leaf) }
            let leafError = errno
            guard status == -1, leafError == ENOENT else { throw rejected() }
            return result
        }

        static func operatorSignal(_ data: Data, runID: String, pid: Int32, configSHA256: String,
                                   readySHA256: String, readyTicks: UInt64, observedTicks: UInt64) throws -> [String: Any] {
            func rejected() -> NSError {
                NSError(domain: "Feather.MatchedRetainedMemory", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid matched-memory operator acknowledgement."])
            }
            guard data.count <= 16 * 1_024,
                  let signal = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(signal.keys) == Set(["schema", "runID", "pid", "configSHA256", "operatorReadySHA256", "signalMachTicks"]),
                  signal["schema"] as? String == "feather-matched-retained-memory-operator-start-v1",
                  signal["runID"] as? String == runID, signal["pid"] as? Int32 == pid,
                  signal["configSHA256"] as? String == configSHA256,
                  signal["operatorReadySHA256"] as? String == readySHA256,
                  let number = signal["signalMachTicks"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.stringValue.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil,
                  let ticks = UInt64(number.stringValue), readyTicks > 0,
                  ticks >= readyTicks, ticks <= observedTicks else { throw rejected() }
            return signal
        }

        static func read(_ path: String, operatorStartPath: String? = nil) throws -> Self {
            func rejected(_ reason: String) -> NSError {
                NSError(domain: "Feather.MatchedRetainedMemory", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: reason])
            }
            func bounded(_ path: String, maximum: Int) throws -> Data {
                guard path.hasPrefix("/"), let handle = FileHandle(forReadingAtPath: path) else {
                    throw rejected("An absolute readable matched-memory input is required.")
                }
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximum + 1) ?? Data()
                guard data.count <= maximum else { throw rejected("Matched-memory input exceeds its bound.") }
                return data
            }
            let data = try bounded(path, maximum: 16 * 1_024)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["schema", "runID", "privateRoot", "privateHome", "urls", "probeScript", "probeSHA256", "readyReport", "finalReport", "sampleWindowReceipt", "viewportWidth", "viewportHeight"]),
                  object["schema"] as? String == "feather-matched-retained-memory-config-v1",
                  let runID = object["runID"] as? String,
                  runID.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil,
                  let rootPath = object["privateRoot"] as? String,
                  let homePath = object["privateHome"] as? String,
                  let rawURLs = object["urls"] as? [String], [1, 8].contains(rawURLs.count),
                  let probePath = object["probeScript"] as? String,
                  let expectedProbeHash = object["probeSHA256"] as? String,
                  expectedProbeHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  object["viewportWidth"] as? Int == 1000, object["viewportHeight"] as? Int == 700 else {
                throw rejected("Invalid matched-memory configuration schema or bounds.")
            }
            func canonical(_ value: String) -> URL { URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath() }
            let root = canonical(rootPath), home = canonical(homePath)
            let environmentHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]
            let isolationChecks: [String: Bool] = [
                "absoluteRoot": rootPath.hasPrefix("/"),
                "absoluteHome": homePath.hasPrefix("/"),
                "rootParent": root.deletingLastPathComponent().path == canonical("/private/tmp").path,
                "rootName": root.lastPathComponent == "feather-matched-retained-memory-" + runID,
                "homeWithinRoot": home.path == root.appendingPathComponent("home").path,
                "bundleIdentifier": Bundle.main.bundleIdentifier == "dev.nesbes.Feather.MatchedRetainedMemory." + runID,
                "bundleWithinRoot": Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                "configWithinRoot": canonical(path).path.hasPrefix(root.path + "/"),
                "probeWithinRoot": canonical(probePath).path.hasPrefix(root.path + "/"),
                "environmentHomePresent": environmentHome != nil,
                "environmentHomeMatches": environmentHome.map({ canonical($0) == home }) == true,
                "foundationHomeMatches": canonical(NSHomeDirectory()) == home,
                "applicationSupportWithinHome": FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map({ canonical($0.path).path.hasPrefix(home.path + "/") }) == true
            ]
            let failedIsolation = isolationChecks.keys.filter { isolationChecks[$0] != true }.sorted()
            guard failedIsolation.isEmpty else {
                throw rejected("Matched-memory owned/private-home checks failed: " + failedIsolation.joined(separator: ","))
            }
            for directory in [root, home] {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                    throw rejected("Matched-memory root and home must be owned private0700 directories.")
                }
            }
            let support = home.appendingPathComponent("Library/Application Support/Feather")
            guard !FileManager.default.fileExists(atPath: support.appendingPathComponent("session.json").path),
                  !FileManager.default.fileExists(atPath: support.appendingPathComponent("history.sqlite").path) else {
                throw rejected("Matched-memory mode requires a fresh private profile.")
            }
            var urls: [URL] = []
            for (index, value) in rawURLs.enumerated() {
                guard let components = URLComponents(string: value), let url = components.url,
                      components.scheme == "http", components.host == "127.0.0.1",
                      let port = components.port, (1024...65535).contains(port),
                      components.user == nil, components.password == nil,
                      components.query == nil, components.fragment == nil,
                      components.path == "/page-\(index)", value == "http://127.0.0.1:\(port)/page-\(index)",
                      urls.first.map({ BenchmarkRunner.sameOrigin($0, url) }) ?? true else {
                    throw rejected("Matched-memory URLs must be exact contiguous loopback fixture pages.")
                }
                urls.append(url)
            }
            let probeData = try bounded(probePath, maximum: 32 * 1_024)
            let actualProbeHash = SHA256.hash(data: probeData).map { String(format: "%02x", $0) }.joined()
            guard actualProbeHash == expectedProbeHash, let probeSource = String(data: probeData, encoding: .utf8) else {
                throw rejected("Matched-memory shared probe fingerprint or encoding differs.")
            }
            func output(_ key: String) throws -> URL {
                guard let raw = object[key] as? String, raw.hasPrefix("/") else { throw rejected("Missing matched-memory receipt path.") }
                return try Self.freshOwnedOutput(raw, root: root, excludedInputs: [canonical(path), canonical(probePath)],
                                                canonical: canonical)
            }
            let ready = try output("readyReport"), final = try output("finalReport"), receipt = try output("sampleWindowReceipt")
            guard Set([ready, final, receipt]).count == 3 else { throw rejected("Matched-memory receipt paths must be distinct.") }
            var operatorStart: URL?, operatorReady: URL?
            if let operatorStartPath {
                let exclusions = [canonical(path), canonical(probePath), ready, final, receipt]
                let gateReady = try Self.freshOwnedOutput(root.appendingPathComponent("operator-ready.json").path,
                                                         root: root, excludedInputs: exclusions, canonical: canonical)
                let gateStart = try Self.freshOwnedOutput(operatorStartPath, root: root,
                                                         excludedInputs: exclusions + [gateReady], canonical: canonical)
                guard gateStart.path == root.appendingPathComponent("operator-start.json").path else {
                    throw rejected("Matched-memory operator gate must use its fixed owned signal path.")
                }
                operatorStart = gateStart
                operatorReady = gateReady
            }
            return Self(runID: runID, root: root, urls: urls, probeSource: probeSource,
                        probeSHA256: actualProbeHash,
                        configSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        readyReport: ready, finalReport: final, sampleWindowReceipt: receipt,
                        operatorStart: operatorStart, operatorReady: operatorReady)
        }
    }
    struct NativeFocusLoss: Codable {
        var event: String
        var secondsAfterStart: Double
    }

    private final class NativeFocusTrace {
        private var observers: [NSObjectProtocol] = []
        private var started: TimeInterval?
        private var losses: [NativeFocusLoss] = []

        init(window: NSWindow) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record("applicationResignedActive") }
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record("benchmarkWindowResignedKey") }
            })
        }

        func start() { started = ProcessInfo.processInfo.systemUptime }
        private func record(_ event: String) {
            guard let started else { return }
            losses.append(NativeFocusLoss(event: event, secondsAfterStart: ProcessInfo.processInfo.systemUptime - started))
        }
        func finish() -> [NativeFocusLoss] {
            started = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            return losses
        }
    }

    private final class ReceiptSessionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    struct StandardSuiteRequest {
        var name: String
        var controllerSource: String?
        var controllerSHA256: String?
        var timeout: TimeInterval
        var viewportWidth: Double
        var viewportHeight: Double
        var maximizeWindow: Bool
        var operatorStartSignal: URL?
        var resultURL: URL?
        var resultToken: String?
        var configurationError: String?
    }

    struct StandardSuiteResult: Codable {
        var name: String
        var completed: Bool
        var controllerSHA256: String?
        var resultJSON: String?
        var error: String?
        var elapsedSeconds: Double
        var thermalStateAtStart: Int
        var thermalStateAtEnd: Int
        var lowPowerMode: Bool
        var nativeApplicationActiveAtStart: Bool?
        var nativeApplicationActiveAtEnd: Bool?
        var nativeWindowKeyAtStart: Bool?
        var nativeWindowKeyAtEnd: Bool?
        var nativeWebViewResponderAtStart: Bool?
        var nativeWebViewResponderAtEnd: Bool?
        var nativeFocusMonitoring: String?
        var nativeFocusLosses: [NativeFocusLoss]?
        var requestedMaximizedWindow: Bool?
        var windowFillsVisibleFrameAtStart: Bool?
        var windowFillsVisibleFrameAtEnd: Bool?
        var screenMaximumFramesPerSecondAtStart: Int?
        var screenMaximumFramesPerSecondAtEnd: Int?
        var operatorStartGateUsed: Bool?
        var completionTransport = "Authenticated loopback HTTP receipt; no page status polling during timed work."
        var memorySampleScope = "Before/after only; use external sampling for benchmark peak memory."
    }

    struct Sample: Codable {
        var t: Double
        var totalMB: Double
        var appMB: Double
        var webContentMB: Double
        var networkMB: Double
        var gpuMB: Double
        var webContentProcesses: Int
        var liveTabs: Int
        var openTabs: Int
    }

    struct Report: Codable {
        var profile: String
        var automaticallyUnloadsTabs: Bool
        var processTuning: Bool
        var urls: [String]
        var interval: Double
        var settle: Double
        var samples: [Sample]
        var peakMB: Double
        var finalMB: Double
        /// End state, for checking fixture pages.
        var tabTitles: [String]?
        var toasts: [String]?
        var popups: [String]?
        var media: [String]?
        /// "Group name: tab, tab" per tab group, after -BenchmarkGroupTabs.
        var groups: [String]?
        /// Present only with explicit -BenchmarkYouTube YES. No playback commands are issued.
        var youtubeObservations: [BenchmarkYouTubeProbe.Observation]?
        /// Total confirmed foreground notices; omitted from ordinary benchmark reports.
        var youtubeCatchNoticesShown: Int?
        /// Bounded native delivery outcomes, with no page data or error messages.
        var youtubeNoticeDelivery: [String: Int]?
        /// Explicit localhost benchmark automation; absent from ordinary URL runs.
        var standardBrowserSuite: StandardSuiteResult?
    }

    private let urls: [URL]
    private let reportURL: URL
    private let interval: TimeInterval
    private let settle: TimeInterval
    private var samples: [Sample] = []
    private let started = Date()
    private let youtubeProbe: BenchmarkYouTubeProbe?
    private let standardSuite: StandardSuiteRequest?
    private var standardSuiteResult: StandardSuiteResult?
    private let matchedMemory: MatchedMemoryRequest?
    var requiresPersistentState: Bool { matchedMemory != nil }

    static func fromArguments() throws -> BenchmarkRunner? {
        let arguments = ProcessInfo.processInfo.arguments
        var operatorStartPath: String?
        if let index = arguments.firstIndex(of: "-BenchmarkMatchedRetainedMemoryStartGate") {
            guard arguments.contains("-BenchmarkMatchedRetainedMemoryConfig"),
                  arguments.filter({ $0 == "-BenchmarkMatchedRetainedMemoryStartGate" }).count == 1,
                  index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
                throw NSError(domain: "Feather.MatchedRetainedMemory", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Operator start gate requires one explicit matched-memory config and absolute signal path."])
            }
            operatorStartPath = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "-BenchmarkMatchedRetainedMemoryConfig") {
            guard arguments.filter({ $0 == "-BenchmarkMatchedRetainedMemoryConfig" }).count == 1,
                  index + 1 < arguments.count,
                  !arguments.contains(where: { ["-BenchmarkURLs", "-BenchmarkBrowserSuite", "-BenchmarkPeek", "-BenchmarkGroupTabs", "-BenchmarkThenURLs", "-BenchmarkYouTube", "-FeatherAgentBridge", "-FeatherWelcomePreview"].contains($0) }) else {
                throw NSError(domain: "Feather.MatchedRetainedMemory", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Matched-memory mode cannot be combined with other automation modes."])
            }
            let request = try MatchedMemoryRequest.read(arguments[index + 1], operatorStartPath: operatorStartPath)
            return BenchmarkRunner(urls: request.urls, reportURL: request.finalReport, interval: 1.2, settle: 80,
                                   matchedMemory: request)
        }
        let defaults = UserDefaults.standard
        guard let list = defaults.string(forKey: "BenchmarkURLs"), let report = defaults.string(forKey: "BenchmarkReport"),
              let text = try? String(contentsOfFile: list, encoding: .utf8) else { return nil }
        let urls = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap(URL.init(string:))
        let interval = defaults.double(forKey: "BenchmarkInterval")
        let settle = defaults.double(forKey: "BenchmarkSettle")
        var suite: StandardSuiteRequest?
        if ProcessInfo.processInfo.arguments.contains("-BenchmarkBrowserSuite") {
            let name = defaults.string(forKey: "BenchmarkBrowserSuite") ?? ""
            var source: String?
            var digest: String?
            var error: String?
            if let path = defaults.string(forKey: "BenchmarkControllerScript"),
               path.hasPrefix("/"), let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
               let data = try? handle.read(upToCount: 256 * 1_024 + 1),
               data.count <= 256 * 1_024, let text = String(data: data, encoding: .utf8) {
                source = text
                digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else { error = "An absolute UTF-8 benchmark controller of at most 256 KiB is required." }
            if urls.count != 1 || !urls.allSatisfy({
                ["http", "https"].contains($0.scheme?.lowercased() ?? "")
                    && ["localhost", "127.0.0.1", "::1", "[::1]"].contains($0.host()?.lowercased() ?? "")
            }) { error = "Standard-suite automation requires exactly one loopback HTTP(S) URL." }
            let resultURL = defaults.string(forKey: "BenchmarkResultURL").flatMap(URL.init(string:))
            let resultToken = defaults.string(forKey: "BenchmarkResultToken")
            if let page = urls.first, let endpoint = resultURL,
               Self.sameOrigin(page, endpoint), page.user == nil, page.password == nil,
               endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
               endpoint.path.range(of: #"^/_feather-results/[A-Za-z0-9_-]{1,96}$"#, options: .regularExpression) != nil,
               let token = resultToken, !token.isEmpty, token.utf8.count <= 256,
               token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) {
                // A fresh collector receipt lets the native task wait without
                // injecting status queries into the benchmark's timed work.
            } else { error = "A same-origin loopback result endpoint and an ASCII receipt token are required." }
            let deadline = defaults.double(forKey: "BenchmarkDeadlineSeconds")
            var startSignal: URL?
            if let path = defaults.string(forKey: "BenchmarkStartSignal") {
                if path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) {
                    startSignal = URL(fileURLWithPath: path)
                } else { error = "The operator start signal must be a fresh absolute file path." }
            }
            suite = StandardSuiteRequest(name: name, controllerSource: source, controllerSHA256: digest,
                                         timeout: deadline > 0 ? min(max(deadline, 30), 3_600) : 900,
                                         viewportWidth: defaults.double(forKey: "BenchmarkViewportWidth"),
                                         viewportHeight: defaults.double(forKey: "BenchmarkViewportHeight"),
                                         maximizeWindow: defaults.bool(forKey: "BenchmarkMaximizeWindow"),
                                         operatorStartSignal: startSignal,
                                         resultURL: resultURL, resultToken: resultToken,
                                         configurationError: error)
        }
        return BenchmarkRunner(urls: urls, reportURL: URL(fileURLWithPath: report),
                               interval: interval > 0 ? interval : 6, settle: settle > 0 ? settle : 45,
                               youtube: BenchmarkYouTubeProbe.explicitlyRequested, standardSuite: suite)
    }

    init(urls: [URL], reportURL: URL, interval: TimeInterval, settle: TimeInterval, youtube: Bool = false,
         standardSuite: StandardSuiteRequest? = nil, matchedMemory: MatchedMemoryRequest? = nil) {
        self.urls = urls
        self.reportURL = reportURL
        self.interval = interval
        self.settle = settle
        youtubeProbe = youtube ? BenchmarkYouTubeProbe() : nil
        self.standardSuite = standardSuite
        self.matchedMemory = matchedMemory
    }

    func start(with state: BrowserState) {
        if let matchedMemory {
            Task { await runMatchedRetainedMemory(matchedMemory, with: state) }
            return
        }
        if let standardSuite {
            Task { await runStandardSuite(standardSuite, with: state) }
            return
        }
        Task {
            let sampler = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample(state) }
            }
            for url in urls {
                guard let window = state.keyWindow ?? state.windows.first else { break }
                state.openTab(url, in: window)
                try? await Task.sleep(for: .seconds(interval))
            }
            // Test hook: -BenchmarkPeek URL previews a link from the last tab, as ⇧-click does.
            if let peek = UserDefaults.standard.string(forKey: "BenchmarkPeek").flatMap(URL.init(string:)),
               let window = state.keyWindow, let tab = window.activeTab, let nsWindow = tab.webView?.window {
                PeekWindowController.show(peek, from: tab, in: nsWindow, state: state)
            }
            // Test hook: -BenchmarkGroupTabs YES runs Group Tabs Now on the front space.
            if UserDefaults.standard.bool(forKey: "BenchmarkGroupTabs"), let window = state.keyWindow ?? state.windows.first {
                await state.grouper.organize(window.space, window: window, manual: true)
                // -BenchmarkThenURLs file: open more tabs, then group again (new tabs should join groups).
                if let more = UserDefaults.standard.string(forKey: "BenchmarkThenURLs"),
                   let text = try? String(contentsOfFile: more, encoding: .utf8) {
                    for url in text.split(separator: "\n").compactMap({ URL(string: String($0)) }) {
                        state.openTab(url, in: window)
                        try? await Task.sleep(for: .seconds(interval))
                    }
                    await state.grouper.organize(window.space, window: window, manual: true)
                }
            }
            try? await Task.sleep(for: .seconds(settle))
            sampler.invalidate()
            sample(state)
            await youtubeProbe?.finish()
            write(state)
            NSApp.terminate(nil)
        }
    }

    /// An explicit owned-profile experiment. Product timers and persistence remain active;
    /// the extra BenchmarkRunner sampler is never installed on this path.
    private func runMatchedRetainedMemory(_ request: MatchedMemoryRequest, with state: BrowserState) async {
        var timebase = mach_timebase_info_data_t()
        let timebaseStatus = mach_timebase_info(&timebase)
        let clock: [String: Any] = ["rawUnits": "mach_absolute_time ticks", "nanosecondsNumer": timebase.numer,
                                    "nanosecondsDenom": timebase.denom]
        var errors: [String] = []
        var rows: [[String: Any]] = []
        var views: [(tab: Tab, view: WKWebView)] = []
        var operations: [[String: Any]] = []
        var quietStart: UInt64 = 0, quietEnd: UInt64 = 0, lastPreEnd: UInt64 = 0, firstPostStart: UInt64 = 0
        var sampleWindow: [String: Any] = [:]
        var operatorGate: [String: Any] = ["requested": request.operatorStart != nil, "accepted": false]
        var focusLosses: [NativeFocusLoss] = []
        let mode = "persistent-private-product-external-only"
        func failed(_ message: String) -> NSError {
            NSError(domain: "Feather.MatchedRetainedMemory", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func writeExclusive(_ object: [String: Any], to url: URL) throws {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 2 * 1_024 * 1_024 else { throw failed("Matched-memory receipt exceeds2MiB.") }
            try data.write(to: url, options: .withoutOverwriting)
        }
        func stateRecord() -> [String: Any] {
            ["persistent": state.persistent, "ephemeral": state.lifecycle.factory.ephemeral,
             "liveTabs": state.liveTabs.count, "openTabs": state.allTabs.count,
             "profile": state.settings.profile.rawValue,
             "automaticallyUnloadsTabs": state.settings.policy != .never,
             "extraBenchmarkSamplingTimer": false, "normalProductMonitoring": true,
             "normalProductMonitoringScope": "Unchanged AppDelegate memory.start(),persistent grouping/history/session and product defaults.",
             "websiteDataStoresPersistent": views.map { $0.view.configuration.websiteDataStore.isPersistent }]
        }
        func rect(_ value: NSRect) -> [String: Double] {
            ["x": Double(value.origin.x), "y": Double(value.origin.y), "width": Double(value.width), "height": Double(value.height)]
        }
        func nativeGeometry() -> [[String: Any]] {
            views.enumerated().map { index, item in
                var result: [String: Any] = ["tabIndex": index, "webViewBounds": rect(item.view.bounds),
                    "attachedToWindow": item.view.window != nil, "pageZoom": item.view.pageZoom,
                    "magnification": item.view.magnification]
                if let window = item.view.window {
                    result["windowFrame"] = rect(window.frame)
                    result["windowKey"] = window.isKeyWindow
                    result["backingScaleFactor"] = window.backingScaleFactor
                    if let screen = window.screen {
                        result["screenFrame"] = rect(screen.frame)
                        result["screenVisibleFrame"] = rect(screen.visibleFrame)
                    }
                }
                return result
            }
        }
        func operatorWindowRecord(_ native: NSWindow) -> [String: Any] {
            var result: [String: Any] = ["windowNumber": native.windowNumber, "frame": rect(native.frame),
                "applicationActive": NSApp.isActive, "key": native.isKeyWindow, "visible": native.isVisible,
                "unoccluded": native.occlusionState.contains(.visible), "backingScaleFactor": native.backingScaleFactor]
            if let screen = native.screen {
                result["screenFrame"] = rect(screen.frame)
                result["screenVisibleFrame"] = rect(screen.visibleFrame)
            }
            return result
        }
        func evaluate(_ source: String, in view: WKWebView, tabIndex: Int, operation: String,
                      arguments: [String: Any] = [:]) async throws -> Any? {
            let begin = mach_absolute_time()
            do {
                let value = try await view.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .page)
                operations.append(["tabIndex": tabIndex, "operation": operation, "startMachTicks": begin, "endMachTicks": mach_absolute_time()])
                return value
            } catch {
                operations.append(["tabIndex": tabIndex, "operation": operation, "startMachTicks": begin, "endMachTicks": mach_absolute_time(), "failed": true])
                throw error
            }
        }
        func checkedSnapshot(_ value: Any?, index: Int, phase: String) throws -> [String: Any] {
            guard let snapshot = value as? [String: Any], snapshot["passed"] as? Bool == true,
                  snapshot["runID"] as? String == request.runID, snapshot["tabIndex"] as? Int == index,
                  snapshot["url"] as? String == request.urls[index].absoluteString,
                  snapshot["phase"] as? String == phase else {
                throw failed("Matched-memory \(phase) probe failed for tab\(index): \(String(describing: value)).")
            }
            let shouldBeVisible = phase == "prepare" || index == request.urls.count - 1
            guard let visibility = snapshot["visibility"] as? [String: Any],
                  visibility["state"] as? String == (shouldBeVisible ? "visible" : "hidden"),
                  visibility["hidden"] as? Bool == !shouldBeVisible,
                  visibility["focused"] as? Bool == shouldBeVisible else {
                throw failed("Matched-memory \(phase) hidden/focus state differs for tab\(index).")
            }
            return snapshot
        }
        do {
            guard timebaseStatus == KERN_SUCCESS, timebase.denom > 0, state.persistent,
                  !state.lifecycle.factory.ephemeral, state.spaces.count == 1, state.windows.count == 1,
                  state.allTabs.isEmpty, let window = state.keyWindow ?? state.windows.first else {
                throw failed("Matched-memory mode requires the fresh persistent one-Space product state.")
            }
            let preparationDeadline = ProcessInfo.processInfo.systemUptime + 120
            if let operatorStart = request.operatorStart, let operatorReady = request.operatorReady {
                let candidates = NSApp.windows.filter {
                    guard let controller = $0.windowController as? BrowserWindowController else { return false }
                    return controller.model === window && controller.state === state
                }
                guard candidates.count == 1, let native = candidates.first, native.windowNumber > 0 else {
                    throw failed("Matched-memory operator gate requires its unique actual empty browser window.")
                }
                let readyTick = mach_absolute_time()
                let gateReady: [String: Any] = ["schema": "feather-matched-retained-memory-operator-ready-v1",
                    "runID": request.runID, "pid": ProcessInfo.processInfo.processIdentifier,
                    "configSHA256": request.configSHA256, "probeSHA256": request.probeSHA256,
                    "clock": clock, "readyMachTicks": readyTick, "nativeWindowNumber": native.windowNumber,
                    "modelWindowID": window.id.uuidString, "nativeWindow": operatorWindowRecord(native),
                    "state": stateRecord(), "passed": true]
                let readyData = try JSONSerialization.data(withJSONObject: gateReady, options: [.prettyPrinted, .sortedKeys])
                guard readyData.count <= 16 * 1_024 else { throw failed("Matched-memory operator-ready receipt exceeds its bound.") }
                try readyData.write(to: operatorReady, options: .withoutOverwriting)
                let readyHash = SHA256.hash(data: readyData).map { String(format: "%02x", $0) }.joined()
                operatorGate["readyReceipt"] = gateReady
                operatorGate["readySHA256"] = readyHash
                let operatorDeadline = min(preparationDeadline, ProcessInfo.processInfo.systemUptime + 60)
                // No fixture page exists yet. Only passive bounded control-file checks occur here.
                while !FileManager.default.fileExists(atPath: operatorStart.path) {
                    guard ProcessInfo.processInfo.systemUptime < operatorDeadline else {
                        throw failed("Matched-memory operator acknowledgement timed out before any fixture page opened.")
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard ProcessInfo.processInfo.systemUptime < operatorDeadline else { throw failed("Matched-memory operator acknowledgement arrived too late.") }
                let signalHandle = try FileHandle(forReadingFrom: operatorStart)
                defer { try? signalHandle.close() }
                let signalData = try signalHandle.read(upToCount: 16 * 1_024 + 1) ?? Data()
                let observedTick = mach_absolute_time()
                operatorGate["signalObservedMachTicks"] = observedTick
                operatorGate["signalSHA256"] = SHA256.hash(data: signalData).map { String(format: "%02x", $0) }.joined()
                operatorGate["signalReceipt"] = (try? JSONSerialization.jsonObject(with: signalData)) ?? NSNull()
                _ = try MatchedMemoryRequest.operatorSignal(signalData, runID: request.runID,
                    pid: ProcessInfo.processInfo.processIdentifier, configSHA256: request.configSHA256,
                    readySHA256: readyHash, readyTicks: readyTick, observedTicks: observedTick)
                operatorGate["nativeWindowAtAcceptance"] = operatorWindowRecord(native)
                guard ProcessInfo.processInfo.systemUptime < operatorDeadline,
                      state.persistent, !state.lifecycle.factory.ephemeral, state.allTabs.isEmpty,
                      state.spaces.count == 1, state.windows.count == 1, state.keyWindow === window,
                      NSApp.windows.contains(where: { $0 === native }),
                      (native.windowController as? BrowserWindowController)?.model === window,
                      NSApp.isActive, native.isKeyWindow, native.isVisible, native.occlusionState.contains(.visible) else {
                    throw failed("Matched-memory operator acknowledgement did not leave the same empty visible native window.")
                }
                operatorGate["signalAcceptedMachTicks"] = mach_absolute_time()
                operatorGate["accepted"] = true
            }
            for (index, url) in request.urls.enumerated() {
                let issue = mach_absolute_time()
                if index == 0, request.operatorStart != nil { operatorGate["firstPageIssueMachTicks"] = issue }
                let tab = state.openTab(url, in: window)
                guard let view = tab.webView else { throw failed("A matched-memory tab did not create a web view.") }
                views.append((tab, view))
                rows.append(["tabIndex": index, "url": url.absoluteString, "tabID": tab.id.uuidString, "issueMachTicks": issue])
                try await Task.sleep(for: .seconds(1.2))
            }
            for (index, item) in views.enumerated() {
                while item.view.isLoading || item.view.url == nil {
                    guard ProcessInfo.processInfo.systemUptime < preparationDeadline else { throw failed("Matched-memory readiness timed out.") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard item.view.url == request.urls[index], item.view.configuration.websiteDataStore.isPersistent else {
                    throw failed("Matched-memory document redirected or its store is not persistent.")
                }
                rows[index]["readyMachTicks"] = mach_absolute_time()
                let selectionStart = mach_absolute_time()
                state.select(item.tab, in: window)
                operations.append(["tabIndex": index, "operation": "selectForPreparation", "startMachTicks": selectionStart,
                                   "endMachTicks": mach_absolute_time()])
                while item.view.window == nil || item.view.bounds.width < 100 || item.view.bounds.height < 100 {
                    guard ProcessInfo.processInfo.systemUptime < preparationDeadline else { throw failed("Matched-memory native view attachment timed out.") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let native = item.view.window, let content = native.contentView else { throw failed("Matched-memory native window is unavailable.") }
                native.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                native.makeFirstResponder(item.view)
                // The requested size is never substituted for observed page/native geometry.
                for _ in 0..<3 {
                    content.layoutSubtreeIfNeeded()
                    native.setContentSize(NSSize(width: content.bounds.width + 1000 - item.view.bounds.width,
                                                 height: content.bounds.height + 700 - item.view.bounds.height))
                    content.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                }
                let visibilityDeadline = min(preparationDeadline, ProcessInfo.processInfo.systemUptime + 15)
                var visibilityChecks: [[String: Any]] = []
                while true {
                    guard ProcessInfo.processInfo.systemUptime < visibilityDeadline else {
                        throw failed("Matched-memory selected page did not become actually visible and focused within its preparation deadline.")
                    }
                    let begin = mach_absolute_time()
                    let page = try await evaluate("return {readyState:document.readyState,url:location.href,hidden:document.hidden,visibility:document.visibilityState,focused:document.hasFocus()};",
                                                  in: item.view, tabIndex: index, operation: "preparationVisibility") as? [String: Any] ?? [:]
                    let attached = item.view.window === native
                    let nativeActive = NSApp.isActive, nativeKey = native.isKeyWindow
                    let nativeVisible = native.isVisible, nativeUnoccluded = native.occlusionState.contains(.visible)
                    visibilityChecks.append(["startMachTicks": begin, "endMachTicks": mach_absolute_time(),
                        "page": page, "nativeAttached": attached, "nativeActive": nativeActive,
                        "nativeKey": nativeKey, "nativeVisible": nativeVisible, "nativeUnoccluded": nativeUnoccluded])
                    rows[index]["preparationVisibilityChecks"] = visibilityChecks
                    guard item.tab.webView === item.view, item.view.url == request.urls[index],
                          window.activeTab === item.tab else { throw failed("Matched-memory selected document changed during visibility preparation.") }
                    guard ProcessInfo.processInfo.systemUptime < visibilityDeadline else {
                        throw failed("Matched-memory selected page did not become actually visible and focused within its preparation deadline.")
                    }
                    if attached && nativeActive && nativeKey && nativeVisible && nativeUnoccluded,
                       page["readyState"] as? String == "complete", page["url"] as? String == request.urls[index].absoluteString,
                       page["hidden"] as? Bool == false, page["visibility"] as? String == "visible",
                       page["focused"] as? Bool == true { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                _ = try await evaluate("return \(request.probeSource);", in: item.view, tabIndex: index, operation: "installProbe")
                let args: [String: Any] = ["runID": request.runID, "tabIndex": index, "expectedURL": request.urls[index].absoluteString]
                let prepared = try await evaluate("return globalThis.__matchedRetainedMemoryProbe.prepare(args);", in: item.view,
                                                  tabIndex: index, operation: "prepareProbe", arguments: ["args": args])
                rows[index]["prepared"] = prepared ?? NSNull()
                _ = try checkedSnapshot(prepared, index: index, phase: "prepare")
            }
            // Direct calls preserve the final selected tab. Hidden views are never selected for these probes.
            for (index, item) in views.enumerated() {
                let args: [String: Any] = ["phase": "pre", "runID": request.runID, "tabIndex": index,
                                           "expectedURL": request.urls[index].absoluteString]
                rows[index]["preProbeStartMachTicks"] = mach_absolute_time()
                let value = try await evaluate("return globalThis.__matchedRetainedMemoryProbe.snapshot(args);", in: item.view,
                                               tabIndex: index, operation: "preProbe", arguments: ["args": args])
                rows[index]["pre"] = value ?? NSNull()
                _ = try checkedSnapshot(value, index: index, phase: "pre")
                lastPreEnd = mach_absolute_time()
                rows[index]["preProbeEndMachTicks"] = lastPreEnd
            }
            guard state.allTabs.count == request.urls.count, state.liveTabs.count == request.urls.count,
                  let activeView = views.last?.view, let activeWindow = activeView.window,
                  NSApp.isActive, activeWindow.isKeyWindow else { throw failed("Matched-memory foreground/native tab state is invalid before quiet.") }
            let trace = NativeFocusTrace(window: activeWindow)
            trace.start()
            var ready: [String: Any] = ["schema": "feather-matched-retained-memory-ready-v1", "runID": request.runID,
                "pid": ProcessInfo.processInfo.processIdentifier, "configSHA256": request.configSHA256,
                "probeSHA256": request.probeSHA256, "mode": mode, "clock": clock,
                "lastPreProbeEndMachTicks": lastPreEnd, "quietSleepSeconds": 80,
                "tabs": rows, "nativeGeometry": nativeGeometry(), "state": stateRecord(),
                "operatorGate": operatorGate, "errors": [], "passed": true]
            quietStart = mach_absolute_time()
            ready["quietStartMachTicks"] = quietStart
            try writeExclusive(ready, to: request.readyReport)
            // No page calls, activation, selection, readiness checks or file polling in this interval.
            try await Task.sleep(for: .seconds(80))
            quietEnd = mach_absolute_time()
            focusLosses = trace.finish()
            for (index, item) in views.enumerated() {
                guard item.tab.webView === item.view, item.view.url == request.urls[index], !item.view.isLoading else {
                    throw failed("Matched-memory native document/view changed during quiet.")
                }
                let args: [String: Any] = ["phase": "post", "runID": request.runID, "tabIndex": index,
                                           "expectedURL": request.urls[index].absoluteString]
                let begin = mach_absolute_time()
                if firstPostStart == 0 { firstPostStart = begin }
                rows[index]["postProbeStartMachTicks"] = begin
                let value = try await evaluate("return globalThis.__matchedRetainedMemoryProbe.snapshot(args);", in: item.view,
                                               tabIndex: index, operation: "postProbe", arguments: ["args": args])
                rows[index]["post"] = value ?? NSNull()
                _ = try checkedSnapshot(value, index: index, phase: "post")
                rows[index]["postProbeEndMachTicks"] = mach_absolute_time()
            }
            let receiptHandle = try FileHandle(forReadingFrom: request.sampleWindowReceipt)
            defer { try? receiptHandle.close() }
            let receiptData = try receiptHandle.read(upToCount: 16 * 1_024 + 1) ?? Data()
            guard receiptData.count <= 16 * 1_024,
                  let receipt = try JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
                  Set(receipt.keys) == Set(["schema", "runID", "pid", "configSHA256", "probeSHA256", "sampleStartedMachTicks", "sampleEndedMachTicks", "sampleReportSHA256"]),
                  receipt["schema"] as? String == "feather-matched-retained-memory-sample-window-v1",
                  receipt["runID"] as? String == request.runID,
                  receipt["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier,
                  receipt["configSHA256"] as? String == request.configSHA256,
                  receipt["probeSHA256"] as? String == request.probeSHA256,
                  let sampleHash = receipt["sampleReportSHA256"] as? String,
                  sampleHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw failed("Matched-memory external sample receipt is missing or invalid.")
            }
            func tick(_ key: String) -> UInt64? {
                guard let number = receipt[key] as? NSNumber,
                      number.stringValue.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil else { return nil }
                return UInt64(number.stringValue)
            }
            guard let sampleStart = tick("sampleStartedMachTicks"), let sampleEnd = tick("sampleEndedMachTicks"),
                  lastPreEnd <= quietStart, sampleStart >= quietStart, sampleEnd > sampleStart, sampleEnd <= quietEnd,
                  firstPostStart >= quietEnd,
                  Double(sampleStart - quietStart) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000 >= 35,
                  operations.allSatisfy({ operation in
                      guard let begin = operation["startMachTicks"] as? UInt64 else { return false }
                      return begin < quietStart || begin >= quietEnd
                  }) else { throw failed("Matched-memory sample/probe timing overlaps or violates its quiet interval.") }
            sampleWindow = receipt
            guard state.persistent, !state.lifecycle.factory.ephemeral,
                  state.allTabs.count == request.urls.count, state.liveTabs.count == request.urls.count,
                  focusLosses.isEmpty else { throw failed("Matched-memory product state or native foreground changed during quiet.") }
        } catch {
            errors.append(error.localizedDescription)
        }
        let result: [String: Any] = ["schema": "feather-matched-retained-memory-final-v1", "runID": request.runID,
            "pid": ProcessInfo.processInfo.processIdentifier, "configSHA256": request.configSHA256,
            "probeSHA256": request.probeSHA256, "mode": mode, "clock": clock,
            "quietStartMachTicks": quietStart, "quietEndMachTicks": quietEnd,
            "lastPreProbeEndMachTicks": lastPreEnd, "firstPostProbeStartMachTicks": firstPostStart,
            "sampleWindow": sampleWindow, "tabs": rows, "nativeGeometry": nativeGeometry(), "state": stateRecord(),
            "operatorGate": operatorGate,
            "operations": operations,
            "nativeFocusLosses": focusLosses.map { ["event": $0.event, "secondsAfterStart": $0.secondsAfterStart] as [String: Any] },
            "errors": errors, "passed": errors.isEmpty,
            "functionalScope": "Synthetic draft and document/DOM/timer references across pre/post brackets; no trusted-input or exact sampled-window useful-work claim."]
        do { try writeExclusive(result, to: request.finalReport) }
        catch { fputs("Unable to preserve matched-memory result: \(error.localizedDescription)\n", stderr) }
        NSApp.terminate(nil)
    }

    /// Runs the ordinary browser against unmodified localhost benchmark assets.
    /// The explicit controller is shared with peer-browser automation; it starts
    /// the official UI/client and captures its result without changing engine settings.
    private func runStandardSuite(_ request: StandardSuiteRequest, with state: BrowserState) async {
        let began = ProcessInfo.processInfo.systemUptime
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        var nativeFocusTrace: NativeFocusTrace?
        var result = StandardSuiteResult(name: request.name, completed: false,
                                         controllerSHA256: request.controllerSHA256,
                                         error: request.configurationError, elapsedSeconds: 0,
                                         thermalStateAtStart: thermal, thermalStateAtEnd: thermal,
                                         lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        sample(state)
        if result.error == nil, let url = urls.first, let source = request.controllerSource,
           let window = state.keyWindow ?? state.windows.first {
            let tab = state.openTab(url, in: window)
            do {
                guard let webView = tab.webView else { throw suiteError("The benchmark tab did not create a web view.") }
                let preparationDeadline = ProcessInfo.processInfo.systemUptime + 90
                while webView.isLoading || webView.url == nil {
                    guard ProcessInfo.processInfo.systemUptime < preparationDeadline else { throw suiteError("Page load timed out.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard webView.url == url else { throw suiteError("The benchmark page redirected from its requested URL.") }
                result.requestedMaximizedWindow = request.maximizeWindow
                if request.maximizeWindow, let hostWindow = webView.window, let screen = hostWindow.screen {
                    hostWindow.setFrame(screen.visibleFrame, display: true)
                    hostWindow.contentView?.layoutSubtreeIfNeeded()
                } else if request.viewportWidth >= 850, request.viewportWidth <= 2_560,
                   request.viewportHeight >= 650, request.viewportHeight <= 1_600,
                   let hostWindow = webView.window, let content = hostWindow.contentView {
                    content.layoutSubtreeIfNeeded()
                    hostWindow.setContentSize(NSSize(width: content.bounds.width + request.viewportWidth - webView.bounds.width,
                                                     height: content.bounds.height + request.viewportHeight - webView.bounds.height))
                    content.layoutSubtreeIfNeeded()
                }
                // MotionMark's initial frame calibration also needs a visible
                // window. This is preparation, before any scored work.
                if let hostWindow = webView.window {
                    hostWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    hostWindow.makeFirstResponder(webView)
                }
                _ = try await webView.callAsyncJavaScript(source, contentWorld: .page)
                while true {
                    let ready = try await webView.callAsyncJavaScript("return Boolean(globalThis.__browserBenchController?.ready());", contentWorld: .page) as? Bool == true
                    if ready { break }
                    guard ProcessInfo.processInfo.systemUptime < preparationDeadline else { throw suiteError("Benchmark readiness timed out.") }
                    try await Task.sleep(for: .milliseconds(200))
                }
                result.operatorStartGateUsed = request.operatorStartSignal != nil
                if let signal = request.operatorStartSignal {
                    let ready = signal.deletingLastPathComponent().appendingPathComponent(signal.lastPathComponent + ".ready")
                    try Data("Benchmark controller ready; waiting for operator start.\n".utf8).write(to: ready, options: .withoutOverwriting)
                    let operatorDeadline = ProcessInfo.processInfo.systemUptime + 180
                    while !FileManager.default.fileExists(atPath: signal.path) {
                        guard ProcessInfo.processInfo.systemUptime < operatorDeadline else { throw suiteError("The operator start signal exceeded its deadline.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                // Only this explicit localhost automation path brings its own
                // disposable test window forward. Never score an occluded page.
                if let hostWindow = webView.window {
                    hostWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    hostWindow.makeFirstResponder(webView)
                }
                let focusDeadline = ProcessInfo.processInfo.systemUptime + 30
                while true {
                    let focused = try await webView.callAsyncJavaScript("return !document.hidden && document.hasFocus();", contentWorld: .page) as? Bool == true
                    if focused { break }
                    guard ProcessInfo.processInfo.systemUptime < focusDeadline else { throw suiteError("The benchmark window could not become focused and visible.") }
                    try await Task.sleep(for: .milliseconds(200))
                }
                // Let genuine activation and any preparation UI work settle.
                // This never refocuses a page during scored work.
                try await Task.sleep(for: .seconds(5))
                guard try await webView.callAsyncJavaScript("return !document.hidden && document.hasFocus();", contentWorld: .page) as? Bool == true else {
                    throw suiteError("The benchmark lost its focused and visible state during preparation.")
                }
                result.thermalStateAtStart = ProcessInfo.processInfo.thermalState.rawValue
                result.nativeApplicationActiveAtStart = NSApp.isActive
                result.nativeWindowKeyAtStart = webView.window?.isKeyWindow
                result.nativeWebViewResponderAtStart = Self.hasNativeResponder(webView)
                result.windowFillsVisibleFrameAtStart = Self.fillsVisibleFrame(webView)
                result.screenMaximumFramesPerSecondAtStart = webView.window?.screen?.maximumFramesPerSecond
                guard webView.url == url, let endpoint = request.resultURL, let token = request.resultToken else {
                    throw suiteError("The benchmark URL or result receipt configuration changed before starting.")
                }
                if let hostWindow = webView.window {
                    nativeFocusTrace = NativeFocusTrace(window: hostWindow)
                    nativeFocusTrace?.start()
                    result.nativeFocusMonitoring = "Passive NSApplication.didResignActive and NSWindow.didResignKey notifications through completion receipt."
                }
                _ = try await webView.callAsyncJavaScript("return globalThis.__browserBenchController.start();", contentWorld: .page)
                let deadline = ProcessInfo.processInfo.systemUptime + request.timeout
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: ReceiptSessionDelegate(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                while ProcessInfo.processInfo.systemUptime < deadline {
                    guard tab.webView === webView, Self.isBenchmarkDocument(webView.url, requested: url) else { throw suiteError("The benchmark page or web view changed.") }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    var components = URLComponents(url: endpoint.appendingPathComponent("wait"), resolvingAgainstBaseURL: false)!
                    let wait = min(30, max(0, remaining))
                    components.queryItems = [URLQueryItem(name: "timeout", value: String(wait))]
                    var receiptRequest = URLRequest(url: components.url!, timeoutInterval: wait + 10)
                    receiptRequest.setValue(token, forHTTPHeaderField: "X-Feather-Token")
                    let (data, response) = try await session.data(for: receiptRequest)
                    guard let http = response as? HTTPURLResponse, http.url == receiptRequest.url else {
                        throw suiteError("The result receipt endpoint redirected or returned an invalid response.")
                    }
                    if http.statusCode == 204 { continue }
                    guard http.statusCode == 200, data.count <= 8 * 1_024 * 1_024,
                          let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          receipt["run_id"] as? String == endpoint.lastPathComponent,
                          receipt["received_utc"] is String,
                          let status = receipt["payload"] as? [String: Any] else {
                        throw suiteError("The result receipt was invalid or did not match this run.")
                    }
                    guard tab.webView === webView, Self.isBenchmarkDocument(webView.url, requested: url) else { throw suiteError("The benchmark page or web view changed.") }
                    let encoded = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
                    result.resultJSON = String(data: encoded, encoding: .utf8)
                    if let error = status["error"] as? String { throw suiteError(error) }
                    result.completed = status["completed"] as? Bool == true
                    if !result.completed { throw suiteError("The result receipt did not contain a completed suite.") }
                    break
                }
                if !result.completed { result.error = "The standard suite exceeded its deadline." }
            } catch { result.error = error.localizedDescription }
            if let view = tab.webView {
                result.nativeApplicationActiveAtEnd = NSApp.isActive
                result.nativeWindowKeyAtEnd = view.window?.isKeyWindow
                result.nativeWebViewResponderAtEnd = Self.hasNativeResponder(view)
                result.windowFillsVisibleFrameAtEnd = Self.fillsVisibleFrame(view)
                result.screenMaximumFramesPerSecondAtEnd = view.window?.screen?.maximumFramesPerSecond
            }
        } else if result.error == nil { result.error = "The benchmark request could not be opened." }
        result.nativeFocusLosses = nativeFocusTrace?.finish()
        result.elapsedSeconds = ProcessInfo.processInfo.systemUptime - began
        result.thermalStateAtEnd = ProcessInfo.processInfo.thermalState.rawValue
        standardSuiteResult = result
        sample(state)
        write(state)
        NSApp.terminate(nil)
    }

    private func suiteError(_ message: String) -> NSError {
        NSError(domain: "Feather.StandardBrowserSuite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host()?.lowercased() == second.host()?.lowercased() && port(first) == port(second)
    }

    private static func hasNativeResponder(_ webView: WKWebView) -> Bool {
        guard let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    private static func fillsVisibleFrame(_ webView: WKWebView) -> Bool? {
        guard let window = webView.window, let screen = window.screen else { return nil }
        let frame = window.frame, visible = screen.visibleFrame
        return abs(frame.minX - visible.minX) <= 1 && abs(frame.minY - visible.minY) <= 1
            && abs(frame.width - visible.width) <= 1 && abs(frame.height - visible.height) <= 1
    }

    private static func isBenchmarkDocument(_ current: URL?, requested: URL) -> Bool {
        guard let current, var components = URLComponents(url: current, resolvingAgainstBaseURL: false),
              components.fragment == nil || ["", "running", "summary", "details"].contains(components.fragment!) else { return false }
        // Speedometer switches to #running on start and #summary on completion.
        // Preserve the exact document and query across its official sections.
        components.fragment = nil
        return components.url == requested
    }

    private func sample(_ state: BrowserState) {
        state.memory.sample()
        let usages = state.memory.usages
        func megabytes(_ kind: MemoryMonitor.Usage.Kind) -> Double {
            Double(usages.filter { $0.kind == kind }.reduce(0) { $0 + $1.footprint }) / 1_048_576
        }
        samples.append(Sample(t: Date().timeIntervalSince(started), totalMB: Double(state.memory.total) / 1_048_576,
                              appMB: megabytes(.app), webContentMB: megabytes(.webContent),
                              networkMB: megabytes(.network), gpuMB: megabytes(.gpu),
                              webContentProcesses: usages.filter { $0.kind == .webContent }.count,
                              liveTabs: state.liveTabs.count, openTabs: state.allTabs.count))
        if let youtubeProbe, let t = samples.last?.t { youtubeProbe.requestSample(state, t: t) }
    }

    private func write(_ state: BrowserState) {
        let report = Report(profile: state.settings.profile.rawValue,
                            automaticallyUnloadsTabs: state.settings.policy != .never,
                            processTuning: FTWebKitSPI.isAvailable,
                            urls: urls.map(\.absoluteString), interval: interval, settle: settle, samples: samples,
                            peakMB: samples.map(\.totalMB).max() ?? 0, finalMB: samples.last?.totalMB ?? 0,
                            tabTitles: state.allTabs.map(\.displayTitle), toasts: state.toasts.toasts.map(\.message),
                            popups: state.popups.compactMap { $0.webView.url?.absoluteString },
                            media: state.allTabs.compactMap { tab in tab.media.map { "\(tab.displayTitle): \($0)" } },
                            groups: state.spaces.flatMap { space in
                                space.groups.map { group in
                                    "\(group.name): " + space.tabs(in: group).map(\.displayTitle).joined(separator: " | ")
                                }
                            }, youtubeObservations: youtubeProbe?.observations,
                            youtubeCatchNoticesShown: youtubeProbe == nil ? nil : state.lifecycle.factory.adCatch.noticesShown,
                            youtubeNoticeDelivery: youtubeProbe == nil ? nil : state.lifecycle.factory.adCatch.noticeDelivery,
                            standardBrowserSuite: standardSuiteResult)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: reportURL, options: .atomic)
    }
}
