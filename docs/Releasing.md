# Releasing Feather

Feather's source is hosted at [Nesbesss/Feather](https://github.com/Nesbesss/Feather).
The [0.1.0 preview](https://github.com/Nesbesss/Feather/releases/tag/v0.1.0) is
**0.1.0 (1)** for **macOS 26 or later**, with arm64 and x86_64 in one universal
application. It is explicitly a non-notarized prerelease.

## Prepared outputs

The reviewed local candidate lives in `build/github-release-artifacts-20261028/`:

- `Feather-0.1.0-universal-preview.dmg`: branded drag-to-Applications installer.
- `Feather-0.1.0-universal-preview.zip`: the same app, with a verified round trip.
- `Feather-0.1.0-source.tar.gz`: matching source, build tools, original assets,
  dependency inputs, licenses and a per-file source manifest.
- `SHA256SUMS`, `release-manifest.json` and `release-notes.md`.

The preview uses an ad-hoc signature. It is **not notarized**, and a downloaded
copy may be blocked by macOS. The ordinary release path requires a Developer ID
Application certificate and accepted Apple notarization. An Apple Development
certificate is for development and does not satisfy this release path.

## Build and package a local candidate

Install full Xcode, XcodeGen and Python 3.10 or later. Select Xcode per command with `DEVELOPER_DIR`
when the system still points to Command Line Tools; this avoids changing the
machine's global developer setting.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Tools/Release/build.sh --version 0.1.0 --build 1 --output-dir build/release
python3 -m venv build/package-venv
build/package-venv/bin/python -m pip install -r Tools/Release/requirements.txt
build/package-venv/bin/python Tools/Release/package.py \
  --app build/release/Feather.app --output-dir build/release-artifacts
```

Use a fresh output directory when repackaging. Packaging verifies the input
signature, mounts and verifies the DMG, checks the Applications shortcut and app
file hashes, then extracts and verifies the ZIP. It exports only Git-visible
source files and rejects signing keys, local signing configuration and unexpected
large files. Build output, local experiments, browser profiles and the separate
website are excluded by `.gitignore`.

The signed app embeds `Legal/BUILD-SOURCE.json`. Packaging verifies its input
hashes against the current source and refuses an older or unrelated application.
An extracted source archive can also build and package a preview using its
verified `SOURCE-MANIFEST.json`; public packaging requires a clean Git checkout.

The build script leaves the installed app and browser profile untouched. Local
builds use an ad-hoc signature by default; set a stable development identity in
ignored `Support/Local.xcconfig` for your own daily build.

## Validate before publication

```sh
xcodegen generate
xcodebuild -project Feather.xcodeproj -scheme Feather \
  -destination 'platform=macOS' -derivedDataPath build/tests \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= \
  PROVISIONING_PROFILE_SPECIFIER= test
Tools/make-blocklist.sh --check
python3 -m unittest discover -s Tools -p 'test_feather_agent.py'
node --test Tools/feather-agent.test.mjs Tools/StudyToolsLab/service-worker.test.mjs
```

Review the mounted DMG in Finder. Launch a candidate only with a disposable
profile when doing runtime QA, or deliberately install it after saving current
work. Inspect both architectures with `lipo -archs`; an Intel slice compiling
does not establish that it has been tested on an Intel Mac.

The network list now uses the pinned GPL-3.0 HaGeZi Multi LIGHT input, with
73,103 compiled rules. This changes coverage from the older aggregate. The
original synthesized CC0 tour music replaces the recording whose redistribution
license was not documented. Local backups of the prior resources remain outside
Git. See [third-party notices](../THIRD_PARTY_NOTICES.md).

## Sign and notarize for public downloads

Import your Developer ID Application certificate into your own Keychain and
configure a notarytool Keychain profile using Apple's documented credential
setup. Keep certificates, passwords and profiles outside Git. The scripts never
create credentials or submit anything to Apple unless explicitly invoked.

Commit the reviewed source before public packaging. Then:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_ID_APPLICATION='Developer ID Application: YOUR NAME (TEAMID)'
export NOTARY_KEYCHAIN_PROFILE='feather-notary'
Tools/Release/build.sh --version 0.1.0 --build 1 --output-dir build/release-signed
Tools/Release/notarize.sh --app build/release-signed/Feather.app
build/package-venv/bin/python Tools/Release/package.py \
  --app build/release-signed/Feather.app --output-dir build/public-release --release
```

`--release` checks the app's Developer ID signature, stapled ticket and Gatekeeper
assessment. It signs the DMG, submits it to Apple, requires an Accepted response,
staples its ticket and validates it before writing the final manifest/checksums.
It refuses an uncommitted checkout or a preview signature. Keep the notarization
reports with the release evidence. Notarization success is established by the
returned Apple result, not by these scripts merely existing.

Apple references: [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Put the reviewed release on GitHub

Choose the GitHub owner and repository name before publishing. After reviewing
the source and confirming `git status`, create the initial commit if it does not
yet exist. The commands below document publication for a new repository. The initial
preview is published under Nesbesss/Feather; do not recreate an existing repository.
Replace OWNER when using this process for a different owner.

```sh
gh auth login
git add .
git commit -m 'chore: prepare Feather release'
gh repo create OWNER/Feather --public --source=. --remote=origin --push \
  --description 'A native WebKit browser for macOS'
```

Use the notarized outputs from `build/public-release/`, not the preview folder.
Create a **draft prerelease** for final review:

```sh
gh release create v0.1.0 --repo OWNER/Feather --target main --draft --prerelease \
  --title 'Feather 0.1.0' --notes-file build/public-release/release-notes.md \
  build/public-release/Feather-0.1.0-universal.dmg \
  build/public-release/Feather-0.1.0-universal.zip \
  build/public-release/Feather-0.1.0-source.tar.gz \
  build/public-release/SHA256SUMS \
  build/public-release/release-manifest.json \
  build/public-release/release-notes.md
```

Once the actual repository exists, update README's download section to link to
its Releases page, then publish the reviewed draft in GitHub. Make the matching
source archive as easy to find as the DMG. Add a screenshot from a clean synthetic
browser session if desired. Do not publish personal tabs, cookies or profile data.

The `Build and test` workflow checks source changes. The manually dispatched
`Prepare release candidate` workflow saves preview downloads as Actions artifacts;
it has read-only repository permissions and never publishes or notarizes them.
Running either workflow on GitHub still needs verification after the first push.
