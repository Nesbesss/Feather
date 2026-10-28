# First run and interactive tour

A new installation opens one browser window. A feather arrives in an embedded
welcome card with peaceful background music, mute, Play music, volume, and Skip controls. There is no
separate welcome window. Reduce Motion shows the final feather pose.

Show me around starts a guide over the real browser. Each action advances it:

1. Click the highlighted New Tab button or press ⌘T.
2. Type a site or search in the real address field and press Return. During the
   tour the command bar is a view inside this browser window, rather than a panel.
3. Click the real star to save the page as a Favorite. Already saved pages get
   a Continue step; the guide never removes an existing Favorite.
4. Click the highlighted + beside Spaces, then name the Space in the coaching
   card. Create space makes a real Space, with its own tabs and logins.
5. Finish returns to normal browsing and restores the sidebar policy.

Skip step, Skip tour, Back, and Escape avoid mandatory practice. Canceling address
entry returns to New Tab so it can be retried. Finishing removes tour observers,
tour-only input monitoring, embedded command bar, and overlay, then rearms normal browser observation.
The user's actual choices remain; the guide never automatically navigates,
bookmarks, or creates a Space. Favorite changes immediately update the star.

The welcome remains first-run only. A saved session migrates existing users
without interruption; a started marker resumes an interrupted fresh welcome.
Completion stores FeatherWelcomeCompletedVersion=1 and clears the started marker.
Help→Welcome to Feather, Settings→Getting started, or the empty page's Quick tour
replays the experience without resetting the browser.

## Sound

The user-supplied 142.248-second MP3 is bundled unchanged and loops throughout
the tour with a gentle fade-in. Step changes never restart or stop it. Inactivity
and mute pause at the current position; returning resumes it. Finish stops music
and releases tour-only players. Feedback enabled for normal browsing can remain
available. An intro volume slider adjusts music independently of interaction sounds.

Settings→General→Sounds has independent Click sounds and Typing sounds pickers.
Each offers Off, Tour only (default), and Everywhere in Feather. Everywhere covers
browser controls and websites; the two preferences do not enable each other.
Tour mute gates both kinds of feedback in its browser window.

The mouse monitor is local to Feather and installed only for click mode
Everywhere. A click must finish in the same window within 5 points; drag events,
window movement, and resizing cancel it. Tour action callbacks also filter
keyboard activation so a shortcut does not create a button tap.

The local key-down monitor is installed for typing mode Everywhere, or for Tour
only while a tour window is registered. It requires an active Feather window and
a focused text-input context; noneditable native text views are excluded.
WebKit likewise returns no input context outside editable content, as shown in
its [input-context implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm#L5827).
Printable text, spaces, backspace, and forward delete can sound. Command, Control,
and Option shortcuts, modifier keys, arrows, Tab, Return, function keys, and other
navigation remain quiet. Ordinary page shortcuts outside text fields stay quiet.
Both monitors pass events through unchanged. Typed text is never retained.
Bounded physical-key counters choose sound variations without keeping a sequence;
explicit QA reporting contains aggregate counts, with no event text, URLs, or click positions.
No global input monitor or page script is used, and other apps stay quiet.

Music and the original 35 ms button tap use independent players; duplicate tap
callbacks are suppressed for 80 ms. Typing uses 24 edited recordings from
[Reina0613's CC0 keyboard recording](https://freesound.org/people/Reina0613/sounds/709460/).
Six sound families cover left/middle/right keys, Space, Delete, and punctuation,
with four rotating takes per key. A stable physical-key profile adds small rate,
gain, and stereo-position differences. These are designed families, not claims
that the source identified each original key.

An AVAudioEngine mixes up to eight typing voices so quick keys can overlap.
Enabling the typing scope prepares 512 shared key/variant PCM buffers, with less
than 10 MB of decoded sample payload. Once prepared, key events perform no file
decoding or resampling. A 12 ms guard suppresses duplicates of the same key; different
keys have no shared throttle. The graph pauses 350 ms after typing becomes idle,
and disabling Typing releases its nodes and buffers independently of Click sounds.
Audio configuration changes invalidate the graph so it can rebuild for the new
output. Typing neither restarts music nor interrupts button taps.

The tap is original synthesis inspired by the user's Epidemic Sound reference.
No recording from that site is bundled. Music and tap levels preserve headroom;
no system audio settings change. Player playback/loop/resume/mute/reset and
resource identity are checked; no acoustic output measurement is claimed.

## Verification

Use a distinct QA bundle ID with -FeatherWelcomePreview YES. Its browser session,
history, and WebKit data store are not persisted, and it never marks first-run
completion. Preferences still belong to the QA bundle, hence the distinct ID.
Do not launch a test copy normally: ordinary session storage is shared by name.

The suite contains 129 unit tests covering the existing engine, first-run rules,
cooldowns, tour progress, audio decoding and waveform levels, independent sound
scopes, and mouse/key filtering. The standalone audio/design harness passes 23
tests, including decoding all 24 distinct WAVs, rotating takes, duplicate handling,
and the bounded voice pool. Its explicit --play mode checks simultaneous
music/tap/typing, eight-key overlap, idle pause, pause/resume, mute, looping, and
cleanup. Native QA exercises real controls and complete tour cleanup; its results,
screenshots, and playback evidence are under Tools/UXLab. The current preview is
[typing-creamy-demo.wav](../Tools/UXLab/SoundDesign/typing-creamy-demo.wav).
Playback API success and waveform checks do not establish subjective sound
quality or acoustic latency.

Memory sampling still queries each PID once per sample. Failed favicon fetches
retain their bounded 60-second cooldown. Neither establishes an overall browser
speed percentage.
