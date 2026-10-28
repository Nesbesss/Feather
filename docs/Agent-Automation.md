# Feather for coding agents and computer use

Feather supports two complementary ways to work: native macOS computer use for the whole browser, and an optional local DOM bridge for scripted page work. The bridge is disabled on every ordinary launch.

## Start a local agent session

Choose **Develop → Enable Agent Access for This Session**. The checked menu item and terminal button in the sidebar show when access is on. Click the terminal button or the menu item to turn it off immediately. Quitting Feather also ends access.

The bridge uses a Unix socket, not a network port. Its directory is private (0700), the socket is private (0600), and clients must have the same user ID as Feather. Enabling it grants programs running as your macOS user access to your open tabs and their page content and lets them navigate and interact with those pages. Use an isolated build or space for automation when appropriate.

**Develop → Copy Agent Socket Path** gives the exact path. The main build normally uses:

```text
/tmp/feather-agent-<your-user-id>/dev.nesbes.Feather.sock
```

A build with a different bundle identifier gets a different socket. For a disposable build, opt in at launch explicitly:

```sh
open -n /absolute/path/Feather.app --args -FeatherAgentBridge YES
```

This flag is read only when present on the command line. Access is never restored from a saved preference.

## CLI

Python 3.9 or later is sufficient; no packages are required. Run commands from the repository:

```sh
python3 Tools/feather-agent.py browser.info
python3 Tools/feather-agent.py tabs.list
python3 Tools/feather-agent.py tabs.open --params '{"url":"http://localhost:3000"}'
python3 Tools/feather-agent.py page.snapshot
python3 Tools/feather-agent.py page.fill --params '{"selector":"input[name=title]","value":"Hello Feather"}'
python3 Tools/feather-agent.py page.click --params '{"selector":"button[type=submit]"}'
python3 Tools/feather-agent.py page.screenshot --output /tmp/feather-page.png
```

Use `--socket /absolute/path/to/instance.sock` or set `FEATHER_AGENT_SOCKET` for another instance. Pass `tabID` from `tabs.list` to avoid depending on whichever tab the user currently has selected.

## MCP for Codex and other agents

The same Python file can run as an MCP stdio server. Add a local MCP server using the client application's supported configuration:

```json
{
  "mcpServers": {
    "feather": {
      "command": "python3",
      "args": ["/absolute/path/Feather/Tools/feather-agent.py", "--mcp"]
    }
  }
}
```

For clients using TOML configuration, the equivalent server command is `python3` with arguments `['/absolute/path/Feather/Tools/feather-agent.py', '--mcp']`. Configure a custom socket using the `FEATHER_AGENT_SOCKET` environment variable. Config formats vary by client; the JSON above is an example, not a universal configuration file.

The adapter exposes `feather_browser_info`, `feather_tabs_list`, `feather_tabs_open`, `feather_tabs_select`, `feather_tabs_close`, and `feather_page_*` tools. Screenshots are returned as MCP image content. Other results are JSON text. Website text is untrusted content, and the adapter advertises it as such to the agent.

The adapter can start while agent access is off, but calls will fail with instructions to enable it. Neither the CLI nor MCP enables access automatically.

## Playwright-style JavaScript

Use the dependency-free Node.js client for familiar page and locator operations:

```js
import {connectFeather} from './Tools/feather.mjs';

const browser = await connectFeather();
const page = await browser.newPage('http://localhost:3000');
await page.waitForLoadState();
await page.getByRole('textbox', {name: 'Title'}).fill('Hello Feather');
await page.getByRole('button', {name: 'Save'}).click();
console.log(await page.snapshot());
await page.screenshot({path: '/tmp/feather-page.png'});
await page.close();
await browser.disconnect();
```

`page.locator(css)` offers `click()`, `fill(value)`, `selectOption(value)`, and `press(key)`. `page.getByRole(role, {name})` resolves against a fresh visible DOM snapshot; names match exactly by default, with `exact: false` or a RegExp also supported. Locators require exactly one visible match and report ambiguity. `goto`, `reload`, `goBack`, `goForward`, `bringToFront`, `scroll`, `title`, `url`, `waitForURL`, `waitForLoadState`, and viewport `screenshot` are available.

This is a **Playwright-style client, not the Playwright package**. WKWebView does not expose Chromium's CDP endpoint, so `chromium.connectOverCDP()` cannot connect to Feather. Playwright documents CDP attachment for Chromium-based browsers in its [BrowserType API](https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp). This bridge does not implement Playwright's wire protocol. Existing Playwright test suites, browser contexts, network interception, arbitrary JavaScript evaluation, and Playwright's automatic waits are not supported. Use Playwright's own browsers for those features; use this client to exercise the Feather session itself.

## Native computer use / CUA

Native computer use works independently of the local DOM bridge. **Enable Agent Access** is not required for keyboard, pointer, screenshot, or macOS accessibility control. Give the controlling tool macOS Accessibility permission, plus screen-capture permission if that tool requests it, then select Feather as a native application.

Feather keeps WebKit's native accessibility tree intact. Address controls, tab rows, spaces, favorites, navigation, command suggestions, downloads, and web content have accessible names and identifiers. Useful targets include:

| Control | Accessibility identifier |
| --- | --- |
| Browser window | `feather.window.<UUID>` |
| Address field / address pill | `feather.command.address` / `feather.address` |
| Tab / page content | `feather.tab.<UUID>` / `feather.web-content.<UUID>` |
| Space / new space | `feather.space.<UUID>` / `feather.new-space` |
| Tab group | `feather.tab-group.<UUID>` |
| Find query | `feather.find.query` |
| Downloads / download row | `feather.downloads` / `feather.download.<UUID>` |
| Rename or new-space prompt input | `feather.prompt.input` |

Select a space through its button's press action; the current space exposes the selected trait. Tab rows expose select and close accessibility actions even when their close button is not hovered. Completed download rows expose an **Open download** action. A collapsed sidebar is omitted from the accessibility tree; reveal it with ⌘S before targeting its controls. UUIDs identify the current model objects; find window IDs again after a relaunch.

Native providers can merge SwiftUI list rows, exposing the tab title and URL instead of individual child-button identifiers. In that case target the row by its title/URL or use the tab keyboard shortcuts below. Live CUA inspection verified distinct window, navigation, address, new-tab and space identifiers after relaunch; full native interaction checks were limited by an intermittent macOS ScreenCaptureKit capture failure.

Useful keyboard controls for a computer-use agent:

| Shortcut | Action |
| --- | --- |
| ⌘L | Focus current URL / search |
| ⌘T | Open new-tab command bar |
| ↑ / ↓, Return, Escape | Choose, open, or dismiss a command suggestion |
| ⌘W / ⇧⌘T | Close / reopen a tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘1 … ⌘8 / ⌘9 | Tab number / last tab |
| ⌘[ / ⌘] | Back / forward |
| ⌘R / ⌥⌘R | Reload / bypass cache |
| ⌘F / ⌘G / ⇧⌘G | Find / next / previous match |
| ⌘S | Reveal or hide the sidebar |

CUA handles browser chrome, file pickers, permission prompts, trusted keyboard/mouse gestures, cross-origin iframes, and closed shadow roots. DOM bridge actions dispatch synthetic web events, which some sites intentionally treat differently from physical input. `press` supports Enter (including form submission), Tab (focus movement), and Escape (key events for site handlers); use CUA for text editing keys and shortcuts.

Feather is not automatically added to an existing computer-use provider's supported-browser list. Such providers must support generic macOS accessibility/screenshot input or explicitly integrate this bridge. Native CUA is available through macOS accessibility-enabled tools; no claim of direct Codex browser-plugin registration is made.

## Protocol and limits

Each Unix connection carries one newline-delimited JSON request and response:

```json
{"id":1,"method":"page.click","params":{"tabID":"UUID","ref":"e...-0"}}
```

Responses contain `result` or `error: {code, message}`. Requests are capped at 64 KiB, active connections at eight, and socket operations at 12 seconds. Clients time out after 15 seconds and cap responses at 32 MiB. Navigation allows complete HTTP/HTTPS URLs and `about:blank`; bridge navigation does not launch external apps or read local files.

A snapshot returns URL, title, up to 32,000 characters of visible page text, viewport dimensions, and up to 300 visible semantic/interactable elements with role, name, rect, and reference. Input password values are omitted. Snapshots cover the main document and open shadow roots; they are a useful semantic DOM view, not a complete accessibility tree. Element references expire on a new snapshot or navigation; detached elements are rejected. CSS selectors are checked for exactly one visible match. Clicks reject obscured elements. Filling dispatches both input and change events, including native input setters for common frontend frameworks.

The bridge installs no listener into page JavaScript, exposes no arbitrary evaluate tool, and reads no browsing history, Keychain passwords, or cookies directly. Logged-in pages and screenshots can still contain sensitive information; the user-scoped opt-in grants access to visible browser data. Native Safari Web Inspector remains available for WebKit debugging because Feather's web views are inspectable; see [Apple's inspection documentation](https://developer.apple.com/documentation/safari-developer-tools/enabling-inspecting-content-in-your-apps).

## Client verification

```sh
python3 -m unittest discover -s Tools -p 'test_feather_agent.py'
node --test Tools/feather-agent.test.mjs
```

For the live native regression, run a disposable build with a different bundle identifier, enable Agent Access, and copy its socket path. The test requires an explicit socket, starts its own HTTP fixture on a random loopback port, and creates and closes only its own tab:

```sh
FEATHER_AGENT_LIVE_SOCKET='/absolute/path/copied-from-preview.sock' node Tools/feather-agent.live.mjs
```

It refuses the main `dev.nesbes.Feather` bundle and leaves pre-existing tabs open. It verifies native ref persistence across calls, form input, strict locators, stale refs, navigation, screenshots, socket permissions and delayed I/O, and a real MCP round trip.
