<p align="center">
  <img src="Brand/Feather-AppIcon.png" width="112" alt="Feather app icon">
</p>

<h1 align="center">Feather</h1>

<p align="center">A native macOS browser with room to breathe.</p>

<p align="center">
  Vertical tabs · Separate spaces · WebKit · Swift & SwiftUI
</p>

Feather puts your pages first: a quiet sidebar, a command bar a keystroke away, and a window that picks up the color of the site you are visiting. Built for **macOS 26 or later**, it uses the system WebKit engine and native Mac controls.

## Get Feather

[**Download Feather 0.1.0 Preview for Mac**](https://github.com/Nesbesss/Feather/releases/download/v0.1.0/Feather-0.1.0-universal-preview.dmg) · [All downloads and release notes](https://github.com/Nesbesss/Feather/releases/tag/v0.1.0)

Universal build for **Apple Silicon and Intel**, macOS 26 or later. This early preview is ad-hoc signed and **not notarized**; macOS may block a downloaded copy.

To install:

1. Download the DMG attached to the GitHub release for your Mac.
2. Open it and drag **Feather** into **Applications**.
3. Eject the disk image and open Feather from Applications.

The release notes identify the supported architecture and signing status. A development or ad-hoc signature is not Developer ID signing or Apple notarization; preparation builds may trigger macOS security checks. Only a release explicitly marked as notarized should be treated as such.

## Made for everyday browsing

| | |
| --- | --- |
| **Your tabs, in order** | Vertical tabs, pinned tabs, shared Favorites, split view, and separate spaces with their own cookies and logins. |
| **Go anywhere** | A keyboard-first command bar, history suggestions, and quick previews with Shift-click. |
| **Read and watch** | Reader view, Listen to Page, picture-in-picture, per-tab mute, and a sidebar media player. |
| **Less interruption** | Ad and tracker blocking, automatic cookie rejection, clean links, and SponsorBlock integration. |
| **A little more Mac** | Native settings, Keychain password storage, Touch ID unlock, site colors, and an optional Liquid Glass appearance. |
| **Stay in control** | Tabs retain their running pages by default. Optional inactive-tab unloading trades page state for lower memory use. |

On supported Macs with Apple Intelligence available, on-device models can suggest tab groups and help the sidebar adapt to a site. Compatible WebExtensions can be imported from a store link, a CRX/ZIP package, or a folder; compatibility varies by extension.

[Explore the user guide →](docs/User-Guide.md)

## Before you try it

Feather is experimental. It is not sandboxed and uses private WebKit APIs, so macOS updates can affect compatibility. It is intended for direct distribution rather than the Mac App Store.

Browser extensions use WebKit's runtime. Chrome-only APIs, native messaging, Chrome account sync, and automatic extension updates are unavailable. Passkeys require a browser entitlement granted by Apple and are disabled in builds without it. Password sign-in remains available. See the [user guide](docs/User-Guide.md) for the details.

## Build from source

Install **Xcode 26 or later**, select its developer directory, and install [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Command Line Tools package alone cannot build the app.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Feather.xcodeproj -scheme Feather \
  -configuration Release -derivedDataPath build/dd \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
open build/dd/Build/Products/Release/Feather.app
```

This makes an ad-hoc signed local build. Use your own Apple signing identity for a stable development identity or a signed distribution build; see [Releasing](docs/Releasing.md). Do not enable the passkey entitlement without a matching provisioning profile.

Run the unit tests:

```sh
xcodebuild -project Feather.xcodeproj -scheme Feather \
  -derivedDataPath build/dd CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

## Contribute

Start with [contributing](CONTRIBUTING.md), the [user guide](docs/User-Guide.md), or [agent automation](docs/Agent-Automation.md). Please use the issue templates for reproducible bugs and focused feature requests. Read [security reporting](SECURITY.md) before sharing sensitive information.

## License

Feather's original code is copyright © 2026 the Feather contributors and is licensed under [GPLv3](LICENSE). Bundled third-party components retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md) and the license files alongside their resources. The release candidate includes original CC0 audio and a licensed HaGeZi blocklist.
