# Contributing to Feather

Thanks for helping improve Feather. Small, focused changes are easiest to review.

## Start here

For a bug, include the Feather version, macOS version, Mac architecture, steps to reproduce, and what you expected to happen. Use a disposable test account or a local fixture where possible. Remove browsing history, tokens, passwords, personal URLs, and account information from logs and screenshots.

For a larger feature, open an issue describing the problem and proposed behavior before implementing it.

## Development

The app requires macOS 26 or later, full Xcode 26 or later, and XcodeGen. Follow the [README build instructions](README.md). Generate the Xcode project from `project.yml`; when adding Swift sources, update that file if needed and regenerate the project.

Keep machine-specific signing configuration in `Support/Local.xcconfig`, which is excluded from Git. Never commit certificates, provisioning profiles, credentials, browser profiles, or local session data.

## Changes and validation

- Keep changes focused and explain the user-visible behavior in the pull request.
- Run the unit tests listed in the README for code changes. Add tests for meaningful logic changes and regressions.
- For UI changes, check keyboard access, VoiceOver labels, light and dark appearance, and Reduce Motion where relevant. Include a screenshot or short recording with synthetic data.
- For browser lifecycle work, consider form state, media playback, popups, session restore, and separate-space data isolation.
- Keep private WebKit calls behind `FTWebKitSPI` and use runtime availability checks.
- Preserve third-party license files and record modifications to bundled third-party code.

State what you tested and any remaining limitations. A fixture passing does not establish compatibility with a real signed-in website or every extension.

## Repository layout

`Feather/` contains the app, `FeatherTests/` the unit tests, `Support/` build configuration, `Brand/` identity assets, and `docs/` documentation. The generated `.xcodeproj`, build products, local experiments, and browser data are not source deliverables.

Release packaging and distribution checks are documented in [Releasing](docs/Releasing.md).
