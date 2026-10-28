import WebKit
import os

private let log = Logger(subsystem: "dev.nesbes.Feather", category: "Media")

/// What a tab is playing, for the sidebar player and auto picture-in-picture.
struct MediaState: Equatable {
    var playing: Bool
    var isVideo: Bool
    /// Playing with sound (not muted by the page).
    var audible: Bool
    var inPictureInPicture: Bool
    /// Decoded picture height, e.g. 1080.
    var height: Int = 0
    var title: String
    var artist: String
    var artwork: URL?
}

/// Tracks the page's audio/video elements in Feather's isolated world: reports
/// play/pause, picture-in-picture, and Media Session metadata, and takes
/// commands from Feather (play/pause, mute, picture-in-picture). Runs in every
/// frame, since players such as YouTube embeds live in iframes.
enum MediaScript {
    static let messageName = "featherMedia"

    static let script = WKUserScript(source: """
        (() => {
          if (window.__featherMedia) return;
          let current = null;
          let muted = false;
          const post = (state) => { try { webkit.messageHandlers.\(messageName).postMessage(state); } catch (e) {} };
          const report = () => {
            const el = current;
            if (!el || !el.isConnected) { post({ hasMedia: false }); return; }
            const meta = navigator.mediaSession && navigator.mediaSession.metadata;
            const art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : null;
            post({ hasMedia: true, playing: !el.paused && !el.ended,
                   isVideo: el instanceof HTMLVideoElement && el.videoWidth > 0,
                   audible: !el.muted && el.volume > 0,
                   pip: document.pictureInPictureElement === el, height: el.videoHeight || 0,
                   title: (meta && meta.title) || document.title || '', artist: (meta && meta.artist) || '', artwork: art });
          };
          const onEvent = (event) => {
            const el = event.target;
            if (!(el instanceof HTMLMediaElement)) return;
            if (event.type === 'play' || event.type === 'playing') {
              current = el;
              if (muted) el.muted = true;
            }
            if (el === current) report();
          };
          for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'volumechange', 'resize',
                              'enterpictureinpicture', 'leavepictureinpicture'])
            document.addEventListener(type, onEvent, true);
          const all = () => Array.from(document.querySelectorAll('video, audio'));
          window.__featherMedia = async (command) => {
            if (command === 'mute' || command === 'unmute') {
              muted = command === 'mute';
              all().forEach(el => { el.muted = muted; });
              return true;
            }
            const el = current;
            if (!el || !el.isConnected) return false;
            switch (command) {
              case 'toggle':
                if (el.paused) await el.play(); else el.pause();
                return true;
              case 'enterPiP':
                if (!(el instanceof HTMLVideoElement) || el.paused || document.pictureInPictureElement === el) return false;
                await el.requestPictureInPicture();
                return true;
              case 'exitPiP':
                if (!document.pictureInPictureElement) return false;
                await document.exitPictureInPicture();
                return true;
            }
            return false;
          };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    /// Runs a command in the frame that reported the media (the main frame if none did).
    /// WebKit treats calls from the app as user gestures, so play() and picture-in-picture are allowed.
    @discardableResult
    static func send(_ command: String, to webView: WKWebView, frame: WKFrameInfo?) async -> Bool {
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.__featherMedia ? await window.__featherMedia(command) : false;",
                arguments: ["command": command], in: frame, contentWorld: .defaultClient)
            return result as? Bool == true
        } catch {
            log.debug("Media command \(command, privacy: .public) failed: \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func state(from body: Any) -> MediaState? {
        guard let body = body as? [String: Any], body["hasMedia"] as? Bool == true else { return nil }
        return MediaState(playing: body["playing"] as? Bool ?? false, isVideo: body["isVideo"] as? Bool ?? false,
                          audible: body["audible"] as? Bool ?? false,
                          inPictureInPicture: body["pip"] as? Bool ?? false, height: body["height"] as? Int ?? 0,
                          title: body["title"] as? String ?? "", artist: body["artist"] as? String ?? "",
                          artwork: (body["artwork"] as? String).flatMap(URL.init(string:)))
    }
}
