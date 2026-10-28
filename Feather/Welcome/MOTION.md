# MOTION.md: living illustrations in this project

> Copy this file next to the project's art (for example `src/art/MOTION.md`) and fill in **Part 2** as you learn the project. Part 1 is the method and stays as it is. The `rossark-motion-skill` reads this file first, and Part 2 overrides the skill's defaults.

---

## Part 1. The method

**The goal:** anything drawn (a character, a plant, a flame, a street, a logo, a chart) feels alive and calm. Nothing teleports, nothing bounces, nothing shouts.

### Principles
1. **Never teleport:** interpolate everything; never swap drawings.
2. **Calm by default:** strong curves, no bouncy overshoot.
3. **Small amplitudes:** when unsure, halve it.
4. **Arcs and pivots:** each moving part is a layer rotating around its joint (stem base, hinge, neck, hook).
5. **Overlap and follow-through:** tips and trailing parts move later and further; give each part the same wave with a growing phase delay.
6. **Variety without chaos:**
   - repeated items get a seeded phase, speed and size;
   - nothing moves in sync, and there's no random value per frame.
7. **One main action per scene, plus two or three idle loops.** Side things stay quiet.
8. **Opacity only to appear or disappear.**
9. **The layout never moves:** motion lives inside the drawing.
10. **Reduced motion:** loops freeze on a good frame 0, and one-shots show their final frame.
11. **Nothing runs unseen:** pause off screen, when hidden and in the background.
12. **Enough frames:** anything under ~100 ms flickers at 30 fps; render and export at 60 when you can. Blinks close in ~110 ms and reopen in ~190 ms.
13. **Interface rules:**
    - frequency decides how much (often seen = barely moves; rare moments get the delight);
    - every motion has a purpose;
    - shared elements travel, never teleport;
    - interface moves stay under 300 ms;
    - exits are faster than entrances;
    - nothing appears from scale 0;
    - interruptions continue from the current value.

### The engine
- **Clocks:** a loop clock for idle life, a one-shot clock for a scene that tells an action. One per character, group or scene.
- **Tracks:** keyframes `[ms, value, 'out'?]` read with `track(t, keys)`. The last key equals the first. `track` stops at every key, so use it for one move (a blink, a lid). For acting (a chain of poses), use `flow(t, keys)`, which passes through the keys without stopping and never overshoots.
- **Helpers:**
  - `wave` (−1 to 1), for sway and breathing;
  - `loop` (0 to 1), for drift and falling;
  - `bell`, to fade in and out;
  - `seg`, for one beat of a one-shot;
  - `seeded(i)`, for per-item variety.
- **Curves:**
  - travel uses ease-in-out `(0.77, 0, 0.175, 1)`;
  - open and arrive use ease-out `(0.23, 1, 0.32, 1)`;
  - leaving uses ease-in;
  - endless loops are linear.

### Quick recipes
| Subject | Recipe |
|---|---|
| Character | breathing 1–2 units over 3–5 s; a blink every 3–4 s; pupils glide; head tilt 3–6° |
| Waiting to be tapped | a jiggle every ~270 ms: squash 2%, widen 2%, the bulge trading sides |
| Floating figure | rises in from 30% of its height below, drifts 5% down and up, leaves rising |
| Tail, hair, ears | rotation around the root, phase delayed along the chain, 4–10° |
| Plant | sway 1.5–4° around the base over 3–6 s; leaves on seeded phases |
| Cloth, flag | a wave that travels along the length, growing away from the fixed edge |
| Fire | a lean of 2–4° and a 3–6% stretch on two waves of different periods |
| Smoke, steam | rises 8–14 units and fades in and out with `bell` |
| Water | ripples grow and fade; floating things bob 1–2 units and rock 2° |
| Rain, snow | seeded `loop`s; snow sways sideways |
| Sky | clouds drift over 20–60 s with parallax; sun rays take 30–60 s per turn |
| Lights | a glow of 2–5% over 2–4 s; stars twinkle at seeded times |
| Machines | gears turn linearly by ratio; a clock hand steps with ease-out |
| Phone | ±3° bursts, then a pause |
| Icon, logo | plays once on appear, then rests |
| Chart | a one-shot draw-on, with bars staggered 40–80 ms |

### Acting (a whole character)
- **Every channel:** key pose (`flow`) + idle (`wave`s, never off while on stage) + follow-through (the parent read 90–140 ms earlier) + accents (a `wave` inside a `seg` window).
- **Arms:** an upper arm and a forearm share a round elbow; the forearm points at shoulder angle + elbow bend.
- **Head turns:** slide the face toward the turn (eyes 10, nose 13 in a 100-wide head) and the ears the other way. Blink on the turn.
- **Weight:** the hips shift and carry the upper body, and the legs angle to keep the feet under it.
- **Landing:** hover, then fall with gravity and stretch; squash hard (0.8) on contact and keep the volume (`width = 1 / height^0.6`).
- **In the air:** limp feet (toes down, one knee folded, trading slowly). The shadow stays on the floor and scales with the height.
- **Props:** enter from off screen already moving and roll by distance / radius. The eyes follow them. A kick hits at the middle of the swing; the prop leaves as a throw, spinning, with a short squash.
- **Asymmetry:** the arms never mirror each other.
- **Camera:** a view from a little above is a whole build, not a tweak: the head is 40–50% of the height, the torso is short and narrower than the head, the legs are short, the feet are round from above, and the shadow is a wide oval with the feet in its lower half. Keep it in one `build` object. A flat view keeps a thin pill shadow.
- **Framing:** on a phone, as big as the screen allows, with the feet low.

### From a reference video
- Contact sheets at the full frame rate (`tools/sheet.sh`).
- Measure motion with numbers (`tools/track_edges.py`): a 2% jiggle or a 5% float doesn't show to the eye.
- Sample colors from pixels (`tools/sample_colors.py`).
- Go part by part: feet, shadow, hands, head.
- Compare proportions as ratios of one unit (head widths). "Stretched" means a ratio is far off.
- Compare your render with the reference at the same moments.
- Don't publish a copy of someone else's art.

### Performance
- Everything is a function of one clock's time.
- Draw many items in one SVG or `Canvas`.
- Reset repeating animations to 0 before starting, and cancel them on cleanup.
- Declare curves at the top of the module.

### Workflow
1. Read Part 2 and the art file's header comments.
2. List what could live in the drawing.
3. Pick one main action and two or three idle loops.
4. Split the art into layers at their pivots.
5. Put the numbers in tokens.
6. Check frame 0, the final frames and the loop seams. For a character, look at a contact sheet of every 4th frame of your own render.
7. Run the checks.
8. Hand off: what moves, and what hasn't been seen on a real device.

---

## Part 2. This project

### Where the code is
- Native macOS AppKit browser with SwiftUI cards; no separate welcome window.
- `BrowserTourController.swift` observes actual user actions and owns lifetime.
- `WelcomeTourOverlay.swift` draws the spotlight, forwards highlighted clicks,
  and hosts the intro and small coaching card in `BrowserRootView`.
- `TourAnchor.swift` measures the real sidebar controls after layout.
- `WelcomeMotion.swift` uses one cancellable monotonic clock. It stops at 2.15 s.

### The owner's rules
- 2026-10-25: a feather dropping, sounds, and a short guide on first use.
- Correction: “it should just all be in the same window” and “highlighted things”
  with an interactive tour. The user said the earlier sound was inaudible.
- Practice actual New Tab, address submission, Favorite, and Space controls.
  Space naming and command entry remain in this same browser view during the tour.
- Skip/Back remain available. Nothing browses, bookmarks, or creates a Space
  automatically. A temporary sidebar reveal never changes the user's preference.

### Motion and sound
- Existing FeatherMark asset at 112 pt, or 72 pt for compact windows. Downward arc
  from the shared pose function; a fixed drawing region keeps layout still.
- Reduce Motion shows the final pose immediately. No indefinite clock.
- Feather motion pauses offscreen/inactive/occluded. Background music continues
  between tour steps; inactivity or mute pauses it without losing position.
- Intro and coaching arrive in 180 ms. Reduce Motion removes the fade.
- User-supplied `freesound_community-peaceful-24736.mp3` is bundled unchanged
  as Audio/tour-background.mp3. Its 142.248-second stereo recording loops locally.
  Default playback gain 0.85 suits its quiet source, with a 0.6-second fade-in.
- Shared mute follows every step and form; the intro adds Play music and volume.
  No card transition stops or rewinds the track. Finish stops music and releases
  tour-only voices; feedback enabled Everywhere can continue in normal browsing.
- One original 35 ms soft tap mixes with music; duplicate callbacks are throttled
  at 80 ms. Typing uses 24 edited takes from
  [Reina0613's CC0 keyboard recording](https://freesound.org/people/Reina0613/sounds/709460/):
  six families with four variations. Physical keys keep stable rate, gain, and
  subtle pan while rotating their takes. Family labels describe designed timbres;
  the source does not identify its original keys.
- A dedicated AVAudioEngine supplies eight overlapping typing nodes and 512
  predecoded key/variant buffers, less than 10 MB of sample payload. Scope enable
  prewarms the bank outside normal key handling. Only repeated events for the same
  key within 12 ms are suppressed; different keys retain their attacks. The engine
  pauses after 350 ms idle. Typing Off releases its graph and buffers while the
  independent tap/music players can remain available. Configuration changes
  invalidate the graph for rebuilding. Once prepared, key handling decodes or
  resamples no files.
- Click sounds and Typing sounds have independent Off/Tour only (default)/
  Everywhere in Feather settings. A local mouse monitor is installed only for
  Everywhere clicks. A local key-down monitor is installed for Everywhere typing,
  or for Tour only while a tour window is registered. No global input hooks,
  page scripts, typed-text storage, or event-content recording are used. Fixed
  per-key variation counters are ephemeral; they do not keep a typing sequence.
- Typing requires an active Feather window and a focused text-input context;
  noneditable native text views are excluded. WebKit's
  [input-context implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm#L5827)
  returns nil outside editable content. Printable text, spaces, and delete keys
  can sound; Command/Control/Option shortcuts, modifiers, arrows, Tab, Return,
  function/navigation keys, and page shortcuts outside text fields stay quiet.
- Tour mute gates both feedback modes in its browser window. Normal app controls
  and websites get each sound only after its Everywhere setting is selected.
  Dragging stays quiet; keyboard activation cannot produce a button tap.
  No system audio settings change.

### Checks
- The native suite contains 129 unit tests, including audio decode/waveform,
  click and typing policies, and tour progress/cancel/skip transitions. The
  standalone audio/design harness passes 23 tests, including all 24 decoded takes,
  per-key variation, same-key suppression, and eight-voice bounds. Explicit
  playback checks cover prepare, play, loop, pause/resume, concurrent
  music/tap/typing, eight-key chords, idle pause, mute, and finish. These checks
  do not establish subjective listening quality or acoustic latency.
- Distinct QA bundle ID plus `-FeatherWelcomePreview YES`: no normal session,
  history, WebKit data store, or completion preference updates.
- Native end-to-end: real address, star, inline Space creation, cleanup, and replay.
  Latest keyboard/browser interaction counts belong in the native QA report.
- Overlay harness checks layout at 640×420. Native screenshot proof lives in
  `Tools/UXLab/`; playback proof is `tour-audio-validation.json`.
- Current rendered audio preview: `Tools/UXLab/SoundDesign/typing-creamy-demo.wav`.

### Recurring launch splash (2026-10-26)
- The owner requested a feather flying around the screen whenever Feather is reopened.
- `LaunchSplashMotion.swift` defines one continuous three-curve flight in the browser's existing drawing area; no separate window or desktop overlay. The existing `FeatherMark` settles above the wordmark.
- `LaunchSplashView.swift` draws from the supplied time only. The flight lasts 1.85 s, rests until 2.2 s, then the AppKit owner fades the cover over 0.22 s. No extra sound or endless idle animation.
- `LaunchSplashController.swift` owns one monotonic visible-time clock, pauses it while inactive/occluded/minimized, and removes its timer and event monitor when finished. A 5 s wall deadline prevents a hidden or stalled intro from blocking the browser.
- Click, Skip, Escape, Return, or Space dismiss immediately; browser shortcuts also dismiss before their normal action. Window close cancels without launching the guide or an authorization prompt.
- Reduce Motion presents the final still for 0.35 s, with no flight, scaling, trail, rotation, or fade.
- `AppDelegate` prepares one cover before showing the first restored window, brings that window forward after restore, and starts it before first-run guide/Passkeys UI. Tabs restore underneath immediately. Benchmarks, explicit agent sessions, and welcome-preview launches skip this splash.
- Cold launch and Dock reopen with no visible browser play it; ordinary extra windows and page navigations do not start another cover.
- Offline frames, a preview movie, and native lifetime checks live in `Tools/LaunchSplashLab/`; motion tests cover continuity at both cubic joins, viewport envelopes, determinism, invalid inputs, and a stationary reduced-motion pose.
