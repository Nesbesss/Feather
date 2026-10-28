import Observation

/// Shared by every tour step. Activity/mute changes pause or resume the same
/// track; only the tour owner calls sound.stop() when the tour ends.
@Observable @MainActor
final class WelcomePlaybackState {
    let sound: WelcomeSound
    @ObservationIgnored var clickHandler: (() -> Bool)?
    var live = false {
        didSet { updateAudio() }
    }
    var isMuted = false {
        didSet { updateAudio() }
    }

    init(sound: WelcomeSound? = nil) {
        self.sound = sound ?? WelcomeSound()
    }

    @discardableResult
    func playClick() -> Bool {
        guard live, !isMuted else { return false }
        if let clickHandler { return clickHandler() }
        return sound.playClick()
    }

    private func updateAudio() {
        if live && !isMuted { sound.play() }
        else { sound.pause() }
    }
}
