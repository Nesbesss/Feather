# Feather user guide

Feather is an experimental native macOS browser built with WebKit (Safari's engine). This guide covers its features, implementation, and local development tools.

- Vertical tabs in a sidebar, pinned tabs, a command bar (⌘T / ⌘L) with inline address completion, no toolbar
- **Favorites:** your everyday sites as tiles at the top of the sidebar, the same in every space (⇧⌘D or the ☆ in the address bar)
- **Liquid Glass look (prototype):** Settings → Appearance turns the sidebar, command bar, and banners to glass
- **Smart sidebar:** steps aside on sites with their own sidebar (Gmail, YouTube, ChatGPT, Notion…) and in narrow windows;
  Apple Intelligence confirms per site, on this Mac
- **AI tab groups:** loose tabs are sorted into named, foldable groups ("Travel", "AI", "Swift") by the on-device model
- **Fits each site:** the window takes on the site's theme color, and the link pill moves out from under the pointer
- **Background continuity:** opened tabs keep their running page state with WebKit CPU throttling; unloading is optional
- **Lazy restore:** after a relaunch only the tabs on screen load
- **Passwords:** saved in your Mac's Keychain and filled after Touch ID; sites stay signed in across relaunches
- **Sign-in popups** ("Sign in with Google" and similar) open as small windows that close themselves when done
- **Tab cleanup:** unpinned tabs you haven't looked at for 12 hours move to the space's archive, and the command bar finds them
- **Cookie pop-ups declined automatically** (DuckDuckGo's consent engine), plus the Global Privacy Control signal
- **Clean links:** tracking parameters (`utm_`, `fbclid`, `si=` …) are removed from links you open and URLs you copy
- **Media:** picture-in-picture when you switch away from a video, mute per tab, and a now-playing player in the sidebar
- **Reader view** (⇧⌘R) and **Listen to Page** (⌥⌘L); **Peek** (⇧-click a link) previews it in a floating panel
- **YouTube:** SponsorBlock skips sponsor reads, and videos start at your chosen quality (1080p by default)
- **Extensions:** install compatible Chrome extensions from a Web Store link, CRX/ZIP package, or unpacked folder; manage them in Settings → Extensions
- **Battery saver:** when automatic unloading is enabled, inactive tabs unload sooner on battery or in Low Power Mode
- Spaces with separate cookies and logins, split view, ad and tracker blocking, downloads, and live memory readout

## Identity

Feather's frosted glass mark lives in [`Brand/Feather.svg`](../Brand/Feather.svg), with transparent PNG exports alongside it.
The same artwork appears on the local start screen and in the macOS app icon. To rebuild every icon size and export:

```sh
swift Tools/make-icon.swift
```

The start screen opens the command bar without creating a web process. History suggestions use a covering ranking
index and reusable SQLite statements; favicon downloads are shared per host, with image processing off the UI thread.

## Agents and computer use

**Develop → Enable Agent Access for This Session** enables a private, same-user Unix socket for tab control,
visible DOM snapshots, strict locators, input, and screenshots. It stays off on normal launches. Native accessibility
labels, stable identifiers, and keyboard controls support macOS computer-use tools.

Use `python3 Tools/feather-agent.py --mcp` for an MCP stdio server, the same script as a CLI, or import
`Tools/feather.mjs` for a dependency-free Playwright-style client. Feather uses WKWebView and does not expose a
Chromium CDP endpoint. Setup, examples, and limitations are in [Agent automation](Agent-Automation.md).

## Build and run

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release -derivedDataPath build/dd build
open build/dd/Build/Products/Release/Feather.app
xcodebuild -project Feather.xcodeproj -scheme Feather -derivedDataPath build/dd test   # unit tests
```

The default configuration in `Support/Signing.xcconfig` uses an ad-hoc signature. To use a stable development identity, set your own `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` in the ignored `Support/Local.xcconfig`. A stable signing identity helps preserve Keychain trust across rebuilds. Distribution signing and notarization are separate release steps; see [Releasing](Releasing.md). Feather is not sandboxed and uses private WebKit APIs (see below), so it is intended for direct distribution rather than the Mac App Store.

**Default browser:** Settings → General → **Make Default** (macOS asks you to confirm). Feather then opens http and
https links from other apps and `.html` files. A link that launches Feather opens after your session is restored. macOS
remembers the default by bundle ID and finds the app where it was registered: the build in `build/dd`. If you delete
that folder, links stop opening in Feather until you build and open it again.

## Opening Feather

Each normal launch and Dock reopen after closing the browser window shows a brief feather flight inside the
restored window. Tabs load underneath, then the splash fades away. Click anywhere, choose Skip, or press Escape
to enter immediately. Reduce Motion shows a short still instead. Automated and welcome-preview launches skip it.

## Settings

Settings uses a resizable sidebar window with focused pages for General, Appearance, Sidebar & Tabs, Privacy,
Performance, Media & Sounds, Passwords, and Extensions. Controls save as you change them. Extensions show their
status and actions together; website access, compatibility notes, and diagnostic details expand when needed.

## Browser extensions

**Feather → Settings → Extensions** installs extensions from Chrome Web Store links or IDs, local `.crx`/`.zip`
packages, and unpacked extension folders. Imports are copied into Application Support and start disabled. Review
**Requested access**, then enable the extension. The **Extensions** menu opens each enabled extension's action or popup
for the active browser tab; **Options…** opens its configuration page. Reload existing pages after toggling extensions.

Feather uses WebKit's native WebExtension runtime, with multiple Manifest V2 and V3 extensions sharing a controller
in each Space. Background scripts/workers, content scripts/styles, extension storage, messaging, action popups,
options pages, tab/window operations, downloads, and file pickers use native APIs. Extension data and optional
permission grants are isolated per Space. Removing an extension or deleting a Space removes its extension data.

Compatibility depends on the APIs an extension uses. Chrome-only APIs, native messaging, local-file access, Chrome account sync, and
automatic extension updates are unavailable. Google may decline downloads for unavailable or restricted store items;
local package import remains available. An import passing validation does not guarantee every feature works. The
manager reports native load errors, and optional access requests require an explicit choice in Feather.

[Study Tools for Magister](https://github.com/QkeleQ10/Study-Tools) 3.16.3 is included as an initial extension. It uses
the same runtime as imports, and can be disabled or removed. Its pinned source, MIT license, and small worker
compatibility changes are documented in
[`Feather/Resources/StudyTools/SOURCE-NOTICES.md`](../Feather/Resources/StudyTools/SOURCE-NOTICES.md).

Regression checks:

```sh
xcodebuild -project Feather.xcodeproj -scheme Feather -derivedDataPath build/dd test
xcrun swift Tools/ExtensionsLab/generic-native-smoke.swift
Tools/ExtensionsLab/run-host-smoke.sh
node --test Tools/StudyToolsLab/service-worker.test.mjs
xcrun swift Tools/StudyToolsLab/native-smoke.swift
```

Native smoke tests use generated extensions, loopback fixtures, synthetic Magister responses, and disposable storage.
They verify the extension APIs and Study Tools' request-header capture without a school account. Real grades,
schedules, and school login flows still need a signed-in account for end-to-end verification.

## Favorites

- **Adding:** click ☆ in the address bar, press ⇧⌘D, right-click a tab → Add to Favorites, or drop a link on the grid.
  The tab itself moves into the grid. Until you have four, dashed tiles suggest your most visited sites (then YouTube,
  Gmail, GitHub, Wikipedia); one click adds one. Hide them with the × or in Settings.
- **Using:** a tile opens its site, or switches to it if it's already open. Favorites are shared by every space, but each
  space opens its own tab with that space's cookies and logins. Favorite tabs sleep like any other tab.
- **Saved page:** each favorite remembers a page. A dot on the tile means you've browsed away; click the tile again (or
  right-click → Go to Saved Page) to go back. Right-click → Save Current Page as Favorite updates it.
- **Managing:** drag tiles to reorder. Right-click to rename, edit the address, open in split view, close the tab, or
  remove it (its open tab moves back to the tab list; Undo in the banner).
- Pinned tabs now sit as rows between Favorites and New Tab, like Arc.

## Smart sidebar

Settings → Sidebar & Tabs → Show the sidebar: **Always**, **When there’s room** (default), or **On hover**.

- **What triggers hiding:** a small layout check (`PageLayoutScript`, isolated world, main frame) looks for the site's own
  navigation panel along the left edge, or a page that works like an app (it doesn't scroll itself and is full of
  controls).
- **Apple Intelligence's role:** when a site looks like that, Feather asks Apple's on-device model once whether hiding helps.
  It answers in about a second once loaded. It says yes for mail, chat, AI assistants, video, documents, and design
  tools, and no for encyclopedias, documentation, news, search, and shopping, which only have a table of contents or
  filters there. The answer is remembered per site.
- **While it thinks:** the sidebar doesn't move. If the model takes longer than 4 s (its first load can take ~15 s), the
  layout check decides.
- **Narrow windows:** below 960 pt, the page always gets the whole window.
- **Getting the sidebar back:** touch the left edge and it slides in over the page.
- **Your choice wins:** ⌘S on a site remembers it ("The sidebar will stay hidden on youtube.com", with Undo). Settings
  lists your choices and lets you remove them.

## Tab groups

- **When it runs:** every 5 minutes (first check 90 s after launch), if a space has at least 6 loose tabs and 3 new ones
  since the last run.
- **How it groups:**
  1. **Describe each tab.** Apple's on-device model writes a short note for the tab ("Travel: planning a trip to
     Lisbon") from its title, site, and meta description. These notes describe the purpose of each tab. Each note is made in its
     own request, since listing several tabs in one prompt let neighbouring notes bleed into each other. Notes are kept
     with the tab until its page changes.
  2. **Embed the notes** with NaturalLanguage's on-device contextual embedding (averaged token vectors), centered and
     compared by cosine distance. 
  3. **Cluster with HDBSCAN** (`HDBSCAN.swift`): groups of at least 2 tabs, with a core distance from
     the 2nd-nearest tab. Members far from the rest of their group (average distance > 0.85) are dropped. Tabs that
     fit nowhere stay loose rather than being forced into a group.
  4. **Join existing groups.** A loose tab within 0.75 of an existing group joins it.
  5. **Name new groups.** The model names each one from that group's own titles and notes (one to three words). A
     name that matches an existing group merges into it.
- **Results:** on 20 real tabs it made Swift Programming (4), Lisbon Trip (4), AI Research (3), Pasta Recipes (2),
  Tech News (2), and Headphones (2). YouTube, Claude's sign-in page, and Hugging Face stayed loose. The first run took
  about 40 s; later runs only describe new tabs. A second run with four more tabs put three into their matching groups.
- **Without the embedding model**, tabs whose notes share a topic form a group.
- **Where groups go:** loose tabs stay at the top, where new tabs open, and groups (✨) sit below them. A group folds with
  a click and still shows the tab you're on. Links opened from a grouped tab join its group.
- **Managing groups:** right-click a group to rename it, ungroup it, or close its tabs. Right-click a tab to move it to a
  group, start a new group, or take it out. Tabs you take out aren't regrouped automatically.
- **Running it yourself:** Tabs → Group Tabs Now (⌥⌘G). The banner after each run has Undo.
- **Privacy:** only tab titles and site names go to the model, and the model runs on this Mac. It runs in a system
  process, so it doesn't add to Feather's memory.

## Fitting in with websites

- **Site color:** the window frame (and the peeking sidebar) blends in the site's `theme-color`, like Safari's tinted tab
  bar. The sidebar's text switches between light and dark to stay readable. The page itself is never re-themed. Turn it
  off in Settings → Appearance.
- **Link pill:** the hovered-link pill moves to the other corner when the pointer is under it, so it never covers what
  you're about to click.

## Liquid Glass prototype

Settings → Appearance → **Liquid Glass**. It switches instantly, and turning it off brings the usual look back.

- The window becomes see-through, tinted with the space's color.
- The navigation buttons, address bar, Favorites tiles, the selected tab, the now-playing player, and the footer are
  Liquid Glass (`glassEffect`).
- The command bar and banners are glass panels with glass buttons, and the hovered-link pill is `NSGlassEffectView`.
- Content cards get larger corners and a deeper shadow.
- Try it without changing your saved setting: `open -n Feather.app --args -FeatherGlassInterface YES`.

## Passwords and sign-in

- **Saving:** after you sign in, a banner asks "Save password for … ?" (Save / Never for This Site). Passwords are internet
  passwords in your login keychain, tagged with Feather's creator code `FTHR`; Feather only ever reads its own items.
- **Filling:** click a username or password field to see the saved accounts for that site (same host first, then the rest
  of the same site, e.g. `accounts.google.com` for `google.com`). Choosing one asks for Touch ID or your Mac password, at most
  once every 5 minutes and again after the screen locks. New-password fields offer a strong password.
- **Safety:** the site always comes from WebKit (the frame's security origin), never from the page. A frame only gets
  logins for its own site, and logins saved over HTTPS are never filled into plain-HTTP pages. The form script runs in an
  isolated JavaScript world that pages can't see.
- **Settings → Passwords:** search, show, copy (the clipboard clears after 90 s), delete, and **Import CSV…** from the
  Passwords app, Safari, Chrome, Firefox, or Bitwarden. Feather then offers to move the CSV to the Trash.
- **Staying signed in:** cookies and site storage persist per space, so sites remember you after a relaunch.
- **Sign-in popups:** a sized `window.open` gets a small window with the site's host and a lock in its header. It closes when
  the page calls `window.close()`, and the opener gets the result as in any browser. **Open as Tab** moves it into a tab.

### Passkeys

WebKit only lets an app use passkeys for arbitrary websites (your Mac's passkeys, your phone over Bluetooth via the QR
code, and security keys) if Apple has granted it the **Web Browser Public Key Credential** entitlement
(`com.apple.developer.web-browser.public-key-credential`). This is how Chrome and Firefox do it. Without the entitlement, a
passkey prompt can never succeed. So Feather hides the API (`window.PublicKeyCredential` is undefined, and
`navigator.credentials` refuses passkey requests), and sites such as Google offer password sign-in instead.

#### Enabling passkeys

1. Join the Apple Developer Program (paid) and set your own development team and signing identity in `Support/Local.xcconfig`.
2. In the developer portal, register the App ID `dev.nesbes.Feather` and request the *Web Browser Public Key Credential*
   capability for it. Apple reviews these requests.
3. Once it's granted, create a macOS development provisioning profile for that App ID named **Feather Passkeys** and
   install it (double-click it).
4. Add the entitlement and provisioning-profile settings from `Support/Local.xcconfig.example` to your `Support/Local.xcconfig`, keeping your team and signing identity, then rebuild.

On first launch Feather asks for permission to use passkeys, and Settings → Passwords shows the status. Don't create
`Local.xcconfig` before the profile exists: macOS kills an app that claims this entitlement without a profile allowing it.

## Privacy and reading

- **Cookie pop-ups:** Feather bundles DuckDuckGo's [autoconsent](https://github.com/duckduckgo/autoconsent) (MPL-2.0,
  unmodified, `Resources/Consent`), the engine their browsers use. It recognizes hundreds of consent platforms (OneTrust,
  Cookiebot, Didomi, Quantcast, Google's own …) and clicks "reject all", hiding the banner while it works. It runs in
  Feather's isolated JavaScript world. For the few platforms that only offer a JavaScript opt-out, Feather runs that
  bundled snippet in the page. A hand in the address pill shows when Feather declined cookies on a page.
  `navigator.globalPrivacyControl` is set, which many sites treat as "do not sell or share". Settings → Privacy turns it off.
- **Clean links:** applies to main-frame page loads (before the request goes out), new tabs, Peek, and Copy Page URL. Only
  parameters that exist purely for tracking are removed; YouTube timestamps, search terms, and affiliate tags are kept.
- **Reader view:** Mozilla's [Readability](https://github.com/mozilla/readability) (Apache-2.0, `Resources/Reader`). Each
  page gets only the 4 KB "is this an article?" check; the full extractor loads when you open reader view. The article is
  drawn over the page in a closed shadow root with no extra web process, and the page underneath is made inert.
- **SponsorBlock:** segments come from the community [SponsorBlock](https://sponsor.ajay.app) database. Feather asks with
  only the first 4 hex digits of the video ID's SHA-256, from an ephemeral session without cookies. Skips show a banner
  with Undo. Sponsor reads, self-promotion, and subscribe reminders are skipped.

## Where the memory goes, and what Feather does about it

Almost all of a browser's memory is WebKit processes: one **WebContent** process per live tab (often 100–700 MB for
modern sites), plus shared **Networking** and **GPU** processes. The browser UI itself is small: Feather's app process is
about 45 MB.

| Lever | Where |
|---|---|
| Keep opened tabs' real `WKWebView` and JavaScript state; skip snapshots during ordinary tab switches | `Engine/TabLifecycle.swift` |
| CPU-throttle detached pages without fully suspending them; keep hidden-page timer throttling and process suppression | `Engine/WebViewFactory.swift`, `SPI/WebKitSPI.m` |
| Optional unloading: LRU budget, idle timer, footprint cap; recent tabs, edits, loading, media/capture and popup openers are protected | `Engine/SleepPolicy.swift` (pure, unit-tested) |
| System memory pressure → unload only when opted in; critical → also drop WebKit's idle process cache | `TabLifecycle` |
| No idle processes: one process pool with WebKit's process cache, prewarming, and (Lean) page cache off, and aggressive suspension under pressure | `SPI/WebKitSPI.m` |
| Hidden-page timer throttling and process suppression | `SPI/WebKitSPI.m` |
| Content blocking (bundled HaGeZi domain list, compiled once and memory-mapped by WebKit) | `Engine/ContentBlocker.swift`, `Resources/Blocklist/` |
| Lazy restore and lazy background tabs | `Model/BrowserState.swift` |
| Memory readout attributed per tab, matching Activity Monitor | `Engine/MemoryMonitor.swift` |

Page scripts (password fields, link hover, unsaved-input tracking) are a few KB, run once per document in an isolated
world, and cost nothing in sleeping tabs. Archived tabs are session records with no web view; only the newest 20 keep
their back/forward history, so the session file stays small.

Profiles (Settings → Efficiency):
- **Lean** keeps 4 live tabs and sleeps after 5 min.
- **Balanced** keeps 8 and sleeps after 20 min, with page cache on for instant Back.
- **Unlimited** never sleeps tabs, for comparison.

### Private WebKit API

Private WebKit calls are behind `FTWebKitSPI` and checked with `respondsToSelector:` at runtime. These guards reduce compatibility risks, but macOS updates can still change behavior and require fixes. Used: `_WKProcessPoolConfiguration` (process cache, prewarming, page cache,
aggressive suspension), `-[WKProcessPool _initWithConfiguration:]`, `_clearWebProcessCache`,
`-[WKWebView _webProcessIdentifier]`, `_networkProcessIdentifier`, `_gpuProcessIdentifier`, `_isPlayingAudio`,
`_setPageMuted:` (mute tab), `WKPreferences` hidden-page throttling, and `_setAllowsPictureInPictureMediaPlayback:` (off by
default in a macOS WKWebView).

## Measuring

Background pages stay live by default, including with the Lean profile. **Settings → Performance → Automatically
unload inactive tabs** opts into destructive memory reclamation. Returning to an unloaded tab reloads its page;
`interactionState` keeps navigation history, not the running JavaScript heap. Automatic unloading has a 60-second
recent-use grace period (critical pressure can bypass the grace period, but never form/media/loading/popup protection).
Manual unloading also respects those protections. Archive, relaunch and WebKit process crashes remain separate
boundaries where live page state can be lost.

For meaningful memory measurements, include Feather and its WebKit content, GPU, and network processes. Compare the same pages, account state, timing, and tab-unloading settings. The browser's memory panel is available with ⌥⌘M.

Earlier local experiments used different profiles and lifecycle settings. Those historical measurements are not a current claim that Feather is faster or uses less memory than another browser. Fresh matched measurements and completed, accepted benchmark results are needed for that conclusion.

## Shortcuts

| Keys | Action |
|---|---|
| ⌘T / ⌘L | Command bar: new tab / edit address |
| ⌘W, ⇧⌘T | Close tab, reopen closed tab |
| ⌘1…9 | Select tab |
| ⇧⌘] / ⇧⌘[, ⌃Tab / ⌃⇧Tab | Next / previous tab |
| Tab or → (command bar) | Accept the completed address |
| ⇧⌘K | Clear: archive all unpinned tabs (Undo in the banner) |
| ⌘[ / ⌘] | Back / forward |
| ⌘R | Reload |
| ⌘D | Pin |
| ⇧⌘D | Add to / remove from Favorites |
| ⌥⌘G | Group tabs now (Apple Intelligence) |
| ⌘S | Sidebar: show/hide; in smart mode, remember for this site (hover the left edge to peek) |
| ⇧⌘= | Split view |
| ⌃1…9 | Switch space |
| ⌥⌘M | Memory panel |
| ⌥⌘Z | Unload eligible background tabs (returning reloads them) |
| ⌘F | Find |
| ⇧⌘C, ⌥⇧⌘C | Copy URL, copy link as Markdown |
| ⇧⌘R | Reader view |
| ⌥⌘L | Listen to page |
| ⇧⌘M | Mute tab (or click the speaker on the tab) |
| ⇧-click a link | Peek; ⌘↩ opens it as a tab, Esc closes |

## Layout

```
Feather/
  App/        AppDelegate (menus), AppSettings, SettingsView, PasswordsSettingsView, BenchmarkRunner
  Model/      BrowserState (all tab/space/window operations, archive), Tab, Space, WindowState, session + history stores
  Engine/     TabLifecycle, SleepPolicy, WebViewFactory, WebTabController (WebKit delegates),
              ContentBlocker, MemoryMonitor, URLInput, Favicons, DownloadManager, Passkeys,
              Autocomplete, ArchivePolicy, CookieConsent + ConsentRules, LinkCleaner, MediaController + MediaScript,
              ReaderMode, ReadAloud, YouTubeExtras, PowerState,
              page scripts (ScriptMessageRouter, LinkHoverScript, UnsavedInputTracker)
  Engine/Passwords/  PasswordStore (Keychain), PasswordUnlock (Touch ID), LoginFormScript, PasswordController,
              SiteMatcher, PasswordCSV, StrongPassword
  Window/     BrowserWindowController (window, root layout, find bar), WebPaneView (content cards, split, link pill),
              PopupWindowController (sign-in popups), PeekWindowController, Toasts
  Resources/  Blocklist (content rules), Consent (autoconsent), Reader (Readability); third-party licenses alongside
  Sidebar/    SidebarView (SwiftUI), MemoryPanelView
  CommandBar/ Command bar panel and suggestions
  SPI/        WebKitSPI: the only private API use
Tools/        Release packaging, blocklist generation, icon generation, agent clients, native smoke tests
```
