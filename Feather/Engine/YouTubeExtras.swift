import CryptoKit
import WebKit
import os

/// YouTube extras: SponsorBlock (skip sponsor reads, self-promotion, and
/// subscribe reminders using the community database) and a preferred video
/// quality. The scripts check the host first and do nothing on other sites.
final class YouTubeExtras: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = YouTubeExtras()
    static let messageName = "featherSponsor"

    weak var state: BrowserState?
    private let log = Logger(subsystem: "dev.nesbes.Feather", category: "YouTube")
    /// No cookies or cache shared with browsing.
    private let session = URLSession(configuration: .ephemeral)
    private var cache: [String: [[String: Any]]] = [:]

    static let categories = ["sponsor": "sponsor", "selfpromo": "self-promotion", "interaction": "subscribe reminder"]

    func install(into controller: WKUserContentController, settings: AppSettings) {
        if settings.skipSponsors {
            controller.addUserScript(Self.sponsorScript)
            controller.addScriptMessageHandler(self, contentWorld: .defaultClient, name: Self.messageName)
        }
        if let quality = settings.youtubeQuality.playerLevel {
            controller.addUserScript(Self.qualityScript(level: quality))
        }
    }

    // MARK: SponsorBlock

    /// Isolated world, main frame: watches the main video and jumps over known segments.
    private static let sponsorScript = WKUserScript(source: """
        (() => {
          if (!/(^|\\.)youtube\\.com$/.test(location.hostname) || window.__featherSponsor) return;
          let videoId = null, segments = [], skipped = new Set();
          const post = (message) => webkit.messageHandlers.\(messageName).postMessage(message);
          const currentId = () => { try { const u = new URL(location.href); return u.pathname === '/watch' ? u.searchParams.get('v') : null; } catch (e) { return null; } };
          const refresh = async () => {
            const id = currentId();
            if (id === videoId) return;
            videoId = id; segments = []; skipped = new Set();
            if (!id) return;
            try { const reply = await post({ type: 'segments', videoId: id }); if (videoId === id && Array.isArray(reply)) segments = reply; } catch (e) {}
          };
          const mainVideo = () => document.querySelector('#movie_player video') || document.querySelector('video');
          document.addEventListener('yt-navigate-finish', refresh);
          // Media events don't bubble, so listen in the capture phase.
          document.addEventListener('timeupdate', (event) => {
            const video = event.target;
            if (!(video instanceof HTMLVideoElement)) return;
            refresh();
            if (!segments.length || video !== mainVideo() || document.querySelector('#movie_player.ad-showing')) return;
            const t = video.currentTime;
            for (const s of segments) {
              if (t >= s.start && t < s.end - 0.5 && !skipped.has(s.uuid)) {
                skipped.add(s.uuid);
                video.currentTime = s.end;
                post({ type: 'skipped', category: s.category, start: s.start, end: s.end, uuid: s.uuid });
              }
            }
          }, true);
          window.__featherSponsor = { undo: (uuid) => { const s = segments.find(x => x.uuid === uuid), v = mainVideo(); if (s && v) v.currentTime = s.start; } };
          refresh();
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], message.frameInfo.isMainFrame,
              Self.isYouTube(message.frameInfo.securityOrigin.host) else { return (nil, nil) }
        switch body["type"] as? String {
        case "segments":
            guard let id = body["videoId"] as? String, id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
                return ([Any](), nil)
            }
            return (await segments(for: id), nil)
        case "skipped":
            guard let webView = message.webView, let uuid = body["uuid"] as? String,
                  let tab = state?.tab(showing: webView), let window = state?.window(showing: tab) else { return (nil, nil) }
            let label = Self.categories[body["category"] as? String ?? ""] ?? "segment"
            let length = Int(((body["end"] as? Double) ?? 0) - ((body["start"] as? Double) ?? 0))
            state?.toasts.show("Skipped \(label) (\(length / 60):\(String(format: "%02d", length % 60)))", symbol: "forward.fill",
                               in: window.id, actions: [.init(title: "Undo") {
                Task {
                    _ = try? await webView.callAsyncJavaScript("window.__featherSponsor && window.__featherSponsor.undo(uuid);",
                                                               arguments: ["uuid": uuid], in: nil, contentWorld: .defaultClient)
                }
            }], duration: 5)
            return (nil, nil)
        default:
            return (nil, nil)
        }
    }

    /// Asks SponsorBlock with only the first 4 hex digits of the video ID's SHA-256
    /// (their k-anonymity API), so the server doesn't learn which video you watch.
    private func segments(for videoID: String) async -> [[String: Any]] {
        if let cached = cache[videoID] { return cached }
        let prefix = SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)")!
        let categories = Self.categories.keys.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        components.queryItems = [.init(name: "categories", value: "[\(categories)]"), .init(name: "actionTypes", value: "[\"skip\"]")]
        var request = URLRequest(url: components.url!, timeoutInterval: 6)
        request.setValue("Feather", forHTTPHeaderField: "X-Client-Name")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let videos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            cache[videoID] = []
            return []
        }
        let segments = videos.first { $0["videoID"] as? String == videoID }?["segments"] as? [[String: Any]] ?? []
        let result: [[String: Any]] = segments.compactMap { segment in
            guard let range = segment["segment"] as? [Double], range.count == 2, range[1] > range[0],
                  segment["actionType"] as? String ?? "skip" == "skip" else { return nil }
            return ["start": range[0], "end": range[1], "category": segment["category"] as? String ?? "",
                    "uuid": segment["UUID"] as? String ?? UUID().uuidString]
        }
        cache[videoID] = result
        if cache.count > 200 { cache.removeAll() }
        log.info("SponsorBlock: \(result.count) segments")
        return result
    }

    private static func isYouTube(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    // MARK: Quality

    /// YouTube's player API lives in the page's own JavaScript, so this runs in the
    /// page world. It picks the best available level up to the preferred one, once
    /// per video, so choosing a quality by hand still works.
    private static func qualityScript(level: String) -> WKUserScript {
        WKUserScript(source: """
            (() => {
              if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;
              const order = ['tiny', 'small', 'medium', 'large', 'hd720', 'hd1080', 'hd1440', 'hd2160', 'highres'];
              const want = order.indexOf('\(level)');
              let applied = null;
              const apply = () => {
                const player = document.getElementById('movie_player');
                if (!player || typeof player.getAvailableQualityLevels !== 'function') return;
                const id = player.getVideoData && player.getVideoData().video_id;
                if (!id || id === applied) return;
                const levels = player.getAvailableQualityLevels().filter(q => order.includes(q));
                if (!levels.length) return;
                const fitting = levels.filter(q => order.indexOf(q) <= want).sort((a, b) => order.indexOf(b) - order.indexOf(a));
                const pick = fitting[0] || levels[levels.length - 1];
                try { player.setPlaybackQualityRange(pick, pick); } catch (e) {}
                applied = id;
              };
              document.addEventListener('yt-navigate-finish', () => setTimeout(apply, 400));
              document.addEventListener('playing', apply, true);
              document.addEventListener('loadeddata', apply, true);
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }
}

/// Settings → YouTube → video quality.
enum YouTubeQuality: String, CaseIterable, Identifiable {
    case auto, q2160, q1440, q1080, q720, q480

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto (YouTube decides)"
        case .q2160: "4K (2160p)"
        case .q1440: "1440p"
        case .q1080: "1080p"
        case .q720: "720p"
        case .q480: "480p"
        }
    }

    /// YouTube's player level name.
    var playerLevel: String? {
        switch self {
        case .auto: nil
        case .q2160: "hd2160"
        case .q1440: "hd1440"
        case .q1080: "hd1080"
        case .q720: "hd720"
        case .q480: "large"
        }
    }
}
