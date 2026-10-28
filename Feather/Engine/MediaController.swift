import WebKit

/// Mute, auto picture-in-picture, and the sidebar's now-playing player.
final class MediaController {
    private unowned let state: BrowserState

    init(state: BrowserState) {
        self.state = state
    }

    // MARK: Page reports

    func handle(_ message: WKScriptMessage) {
        guard let tab = state.tab(showing: message.webView) else { return }
        let frame = message.frameInfo
        guard let media = MediaScript.state(from: message.body) else {
            // Only the frame that owns the player can say it's gone.
            if tab.mediaFrame.map({ Self.sameFrame($0, frame) }) ?? true {
                tab.media = nil
                tab.mediaFrame = nil
            }
            return
        }
        // A silent video elsewhere on the page (a muted ad, a preview) doesn't replace one you're listening to.
        if let current = tab.media, current.audible, !media.audible,
           let currentFrame = tab.mediaFrame, !Self.sameFrame(currentFrame, frame) {
            return
        }
        let wasInPictureInPicture = tab.media?.inPictureInPicture ?? false
        tab.media = media
        tab.mediaFrame = frame
        if media.playing { tab.mediaChanged = .now }
        // Closing the PiP window pauses the video; its "back to tab" button leaves it playing.
        if wasInPictureInPicture, !media.inPictureInPicture, media.playing, state.window(showing: tab) == nil,
           let window = state.windows.first(where: { $0.space.contains(tab) }) ?? state.keyWindow {
            state.select(tab, in: window)
            NSApp.activate()
        }
    }

    private static func sameFrame(_ a: WKFrameInfo, _ b: WKFrameInfo) -> Bool {
        a.isMainFrame == b.isMainFrame && a.securityOrigin.host == b.securityOrigin.host
            && a.securityOrigin.protocol == b.securityOrigin.protocol
    }

    // MARK: Commands

    func togglePlayback(of tab: Tab) {
        guard let webView = tab.webView else { return }
        Task { await MediaScript.send("toggle", to: webView, frame: tab.mediaFrame) }
    }

    func togglePictureInPicture(of tab: Tab) {
        guard let webView = tab.webView else { return }
        let entering = !(tab.media?.inPictureInPicture ?? false)
        Task { await MediaScript.send(entering ? "enterPiP" : "exitPiP", to: webView, frame: tab.mediaFrame) }
    }

    func toggleMute(_ tab: Tab) {
        tab.isMuted.toggle()
        applyMute(to: tab)
    }

    /// Also called when a muted tab wakes up with a new web view.
    func applyMute(to tab: Tab) {
        guard let webView = tab.webView else { return }
        if FTWebKitSPI.setAudioMuted(tab.isMuted, webView: webView) { return }
        Task { await MediaScript.send(tab.isMuted ? "mute" : "unmute", to: webView, frame: tab.mediaFrame) }
    }

    // MARK: Auto picture-in-picture

    /// Switching away from a video you're watching keeps it going in a floating window.
    /// Muted autoplay videos (news sites, previews) don't count.
    func tabDidHide(_ tab: Tab) {
        guard state.settings.autoPictureInPicture, let media = tab.media, media.playing, media.isVideo, media.audible,
              !media.inPictureInPicture, let webView = tab.webView else { return }
        Task {
            if await MediaScript.send("enterPiP", to: webView, frame: tab.mediaFrame) { tab.autoPictureInPicture = true }
        }
    }

    /// Coming back puts the video back in the page.
    func tabDidShow(_ tab: Tab) {
        guard tab.autoPictureInPicture, let webView = tab.webView else { return }
        tab.autoPictureInPicture = false
        Task { await MediaScript.send("exitPiP", to: webView, frame: tab.mediaFrame) }
    }

    // MARK: Now playing

    /// The tab the sidebar player shows: something playing elsewhere, else the
    /// most recently paused one.
    func nowPlaying(excluding window: WindowState) -> Tab? {
        state.allTabs
            .filter { tab in
                guard let media = tab.media, !window.isShowing(tab) else { return false }
                return media.audible || media.inPictureInPicture || tab.isMuted
            }
            .max { a, b in
                let (pa, pb) = (a.media?.playing ?? false, b.media?.playing ?? false)
                return pa != pb ? !pa : a.mediaChanged < b.mediaChanged
            }
    }
}
