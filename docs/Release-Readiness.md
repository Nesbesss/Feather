# Feather 0.1.0 release readiness

Prepared on 28 October 2026 for [Nesbesss/Feather](https://github.com/Nesbesss/Feather).
The initial release is a clearly labeled non-notarized preview. No Apple
notarization submission was performed.

## Ready

- Source repository uses `main`, with the application, license, documentation and
  release tooling included. Local build output and personal signing overrides are excluded.
- GPL-3.0 source license selected by the owner, full third-party notices, source
  inputs and reproducible generators retained.
- Branded README, installation/build guide, contribution/security guidance and
  issue templates prepared.
- Universal Release application **0.1.0 (1)** built with Xcode 27.1. Both arm64
  and x86_64 slices verified; minimum deployment target is macOS 26.0.
- **160 native unit tests passed**, with zero failures or skipped tests, on this
  Apple Silicon Mac running macOS 27.0. Intel hardware runtime QA remains open.
- Python agent tests: **12 passed**. JavaScript agent/Study Tools tests:
  **8 passed**. Upstream resource contract suites: **51 checks passed**.
- New network rules reproduced byte-for-byte from pinned source and compiled by
  native WebKit. Source count alone does not establish real-world blocking efficacy.
- Application build inputs are frozen before/after compilation. The signed app
  embeds a manifest binding it to the exported source. An extracted source
  archive also verifies and generates its Xcode project successfully.
- DMG and ZIP signature/hash round trips passed. Checksums and release notes
  accompany the candidate. The DMG has a custom background, app icon and an
  Applications shortcut; packaging uses dmgbuild 1.6.7 for current Finder support.
  Finder visibly rendered the background and both installation icons during QA.
- CI and a manually dispatched preview-artifact workflow are prepared with
  pinned actions. Check the repository Actions page for current execution results.

## Needed before a normal public download

1. Supply a **Developer ID Application** signing identity and a notarytool
   Keychain profile. This Mac currently has an Apple Development identity only.
2. Commit the reviewed source, rebuild/sign, obtain accepted app and DMG
   notarization, staple and validate both. The scripts implement this path but
   the preview has **not** completed it.
3. Verify GitHub Actions, complete broader runtime QA, and publish the signed
   download with its matching source archive after review.

The prepared preview is ad-hoc signed. It is not represented as a notarized
release, and macOS may block a copy downloaded from the internet. The release
packager refuses its notarized public mode for an ad-hoc signed preview.

## Local evidence and preservation

Build/signature/source evidence is under `build/github-release-20261028/` and
`build/github-release-validation.json`. Test evidence is in
`build/github-release-tests.xcresult`. Packaging evidence and downloads are in
`build/github-release-artifacts-20261028/`. These generated files stay outside
Git; each delivered source archive has a per-file manifest.

The installed Feather app was not replaced, relaunched or pointed at the test
candidate. The personal development signing identity remains in ignored
`Support/Local.xcconfig`. Previous music and network-list resources were backed
up in `build/release-prep-backup/`. The release source uses original CC0 ambient
audio and the pinned GPL-3.0 HaGeZi Multi LIGHT list instead.
