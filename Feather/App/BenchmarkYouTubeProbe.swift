import Foundation
import WebKit

/// Passive observations for explicit -BenchmarkYouTube YES runs only.
/// This does not install scripts, start playback, change consent, or change media policy.
@MainActor
final class BenchmarkYouTubeProbe {
    struct Observation: Codable {
        var t: Double
        var tabID: String
        var frame: String
        var captureStatus: String
        var videoID: String? = nil
        var currentTime: Double? = nil
        var duration: Double? = nil
        var paused: Bool? = nil
        var readyState: Int? = nil
        var mediaError: Int? = nil
        var adShowing: Bool? = nil
        var playabilityStatus: String? = nil
        var adFieldCounts: [String: Int]? = nil
        var protectionVersion: String? = nil
        var upstreamVersion: String? = nil
        var upstreamEligibleRules: Int? = nil
        var upstreamInvokedRules: Int? = nil
        var upstreamFailedRules: Int? = nil
        var adInterventions: Int? = nil
        var catchNoticesSent: Int? = nil
        var policyStampExposed: Bool? = nil
        var catchNoticeAnchor: String? = nil
        var catchNoticeBounds: [String: Double]? = nil
        var catchNoticeState: String? = nil
        var catchNoticePresented: Bool? = nil
        var catchNoticeRepairs: Int? = nil
    }

    private struct Request {
        let state: BrowserState
        let t: Double
    }

    private enum Failure: String, Error {
        case evaluationTimedOut, evaluationFailed, invalidPayload
    }

    private final class Evaluation {
        private var continuation: CheckedContinuation<Result<[String: Any], Failure>, Never>?

        init(_ continuation: CheckedContinuation<Result<[String: Any], Failure>, Never>) {
            self.continuation = continuation
        }

        func complete(_ result: Result<[String: Any], Failure>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: result)
        }
    }

    private(set) var observations: [Observation] = []
    private var pending: Request?
    private var inFlight: Task<Void, Never>?
    private static let maximumObservations = 20_000
    private static let maximumTabsPerSample = 8

    /// An explicit argument is required; a persisted defaults value cannot enable the probe.
    static var explicitlyRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.indices.contains { index in
            arguments[index] == "-BenchmarkYouTube" && index + 1 < arguments.count
                && arguments[index + 1].uppercased() == "YES"
        }
    }

    /// Keep only the latest pending request while a WebKit evaluation is in flight.
    func requestSample(_ state: BrowserState, t: Double) {
        guard observations.count < Self.maximumObservations else { return }
        pending = Request(state: state, t: t)
        guard inFlight == nil else { return }
        inFlight = Task { [weak self] in
            guard let self else { return }
            while let request = pending {
                pending = nil
                await capture(request)
            }
            inFlight = nil
        }
    }

    /// Call after the sampling timer is invalidated and the final request is queued.
    func finish() async {
        while let task = inFlight { await task.value }
    }

    private func capture(_ request: Request) async {
        let activeID = request.state.keyWindow?.activeTab?.id
        let tabs = request.state.liveTabs.sorted { first, second in
            if first.id == activeID { return second.id != activeID }
            if second.id == activeID { return false }
            return first.id.uuidString < second.id.uuidString
        }
        var selected = 0
        for tab in tabs {
            guard observations.count < Self.maximumObservations, selected < Self.maximumTabsPerSample,
                  let webView = tab.webView else { continue }
            let frame: WKFrameInfo?
            let scope: String
            if YouTubeBlockingPolicy.isYouTube(webView.url?.host ?? tab.url?.host) {
                frame = nil
                scope = "main"
            } else if let mediaFrame = tab.mediaFrame, !mediaFrame.isMainFrame,
                      YouTubeBlockingPolicy.isYouTube(mediaFrame.securityOrigin.host) {
                frame = mediaFrame
                scope = "mediaEmbed"
            } else { continue }
            selected += 1
            let arguments: [String: Any] = ["elapsed": request.t, "tabID": tab.id.uuidString, "frameScope": scope]
            let result = await evaluate(webView, frame: frame, arguments: arguments)
            switch result {
            case .success(let payload):
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let observation = try? JSONDecoder().decode(Observation.self, from: data) {
                    observations.append(observation)
                } else {
                    observations.append(Observation(t: request.t, tabID: tab.id.uuidString, frame: scope,
                                                    captureStatus: Failure.invalidPayload.rawValue))
                }
            case .failure(let failure):
                // Do not retain WK error messages: they can include page/request URLs.
                observations.append(Observation(t: request.t, tabID: tab.id.uuidString, frame: scope,
                                                captureStatus: failure.rawValue))
            }
        }
    }

    private func evaluate(_ webView: WKWebView, frame: WKFrameInfo?, arguments: [String: Any]) async -> Result<[String: Any], Failure> {
        await withCheckedContinuation { continuation in
            let evaluation = Evaluation(continuation)
            // A hung WebContent process must not prevent the benchmark's final report.
            let timeout = DispatchWorkItem {
                MainActor.assumeIsolated { evaluation.complete(.failure(.evaluationTimedOut)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
            webView.callAsyncJavaScript(Self.source, arguments: arguments, in: frame, in: .page) { result in
                MainActor.assumeIsolated {
                    timeout.cancel()
                    switch result {
                    case .success(let value):
                        if let payload = value as? [String: Any] { evaluation.complete(.success(payload)) }
                        else { evaluation.complete(.failure(.invalidPayload)) }
                    case .failure:
                        evaluation.complete(.failure(.evaluationFailed))
                    }
                }
            }
        }
    }

    /// Local variables and getters only. No media commands or page-state writes.
    private static let source = #"""
    const base = {t: elapsed, tabID, frame: frameScope};
    const host = String(location.hostname || '').toLowerCase().replace(/\.+$/, '');
    if (!/(^|\.)youtube(?:-nocookie)?\.com$/.test(host)) return {...base, captureStatus: 'frameNoLongerYouTube'};
    const finite = value => typeof value === 'number' && Number.isFinite(value) && Math.abs(value) <= 1e9 ? value : null;
    const count = value => {
      if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return null;
      return Math.min(1000000, Math.floor(value));
    };
    const version = value => typeof value === 'string' && /^[A-Za-z0-9._-]{1,96}$/.test(value) ? value : null;
    const player = document.getElementById('movie_player');
    const video = player?.querySelector('video') || document.querySelector('video');
    let response = null;
    try { if (typeof player?.getPlayerResponse === 'function') response = player.getPlayerResponse(); } catch (_) {}
    if (!response || typeof response !== 'object') response = window.ytInitialPlayerResponse;
    let id = response?.videoDetails?.videoId;
    if (!/^[A-Za-z0-9_-]{11}$/.test(id || '')) {
      try { id = new URLSearchParams(location.search).get('v') || location.pathname.match(/^\/(?:embed|shorts)\/([A-Za-z0-9_-]{11})(?:\/|$)/)?.[1]; } catch (_) {}
    }
    const adFieldCounts = {};
    for (const key of ['adPlacements', 'adSlots', 'playerAds']) {
      const value = response?.[key];
      adFieldCounts[key] = value == null ? 0 : Array.isArray(value) ? Math.min(value.length, 1000000)
        : typeof value === 'object' ? Math.min(Object.keys(value).length, 1000000) : 1;
    }
    const protection = window.__featherYouTubeProtection;
    const upstream = window.__featherYouTubeUpstream;
    const status = response?.playabilityStatus?.status;
    const permittedStatuses = ['OK', 'ERROR', 'UNPLAYABLE', 'LOGIN_REQUIRED', 'CONTENT_CHECK_REQUIRED', 'LIVE_STREAM_OFFLINE', 'AGE_CHECK_REQUIRED'];
    const notice = document.querySelector('#feather-youtube-ad-notice[data-feather-youtube-notice="1"]');
    const noticeRect = notice?.getBoundingClientRect();
    const noticeAnchor = notice?.getAttribute('data-anchor');
    return {...base, captureStatus: 'observed',
      videoID: /^[A-Za-z0-9_-]{11}$/.test(id || '') ? id : null,
      currentTime: finite(video?.currentTime), duration: finite(video?.duration),
      paused: video ? video.paused === true : null, readyState: count(video?.readyState),
      mediaError: video?.error ? count(video.error.code) : null,
      adShowing: player ? player.classList.contains('ad-showing') : null,
      playabilityStatus: typeof status === 'string' ? (permittedStatuses.includes(status) ? status : 'OTHER') : null,
      adFieldCounts: response && typeof response === 'object' ? adFieldCounts : null,
      protectionVersion: version(protection?.version), upstreamVersion: version(upstream?.version),
      upstreamEligibleRules: count(upstream?.eligibleRules), upstreamInvokedRules: count(upstream?.invokedRules),
      upstreamFailedRules: count(upstream?.failedRules),
      adInterventions: count(protection?.adCatches), catchNoticesSent: count(protection?.catchNotices),
      policyStampExposed: typeof globalThis.__featherYouTubePolicyStamp !== 'undefined',
      catchNoticeAnchor: ['logo', 'viewport'].includes(noticeAnchor) ? noticeAnchor : null,
      catchNoticeState: ['waiting','entering','visible','exiting'].includes(notice?.dataset.state) ? notice.dataset.state : null,
      catchNoticePresented: notice ? notice.dataset.presented === 'true' : null,
      catchNoticeRepairs: notice ? count(Number(notice.dataset.repairs || 0)) : null,
      catchNoticeBounds: noticeRect ? {x: finite(noticeRect.x), y: finite(noticeRect.y),
        width: finite(noticeRect.width), height: finite(noticeRect.height)} : null};
    """#
}
