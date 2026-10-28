# Security reporting

Feather is an experimental browser. Use the latest available version; no long-term security support is promised for older builds.

## Report a vulnerability

Do not put passwords, cookies, authentication tokens, browsing history, or exploit details that expose users in a public issue.

Once this repository is on GitHub, use **Security → Report a vulnerability** if private vulnerability reporting is enabled. If it is unavailable, open a minimal public issue requesting a private reporting channel and omit the sensitive details until a maintainer provides one. A dedicated security contact has not yet been published.

A useful private report includes the affected version, macOS version, reproduction steps, the security impact, and a minimal example using synthetic data. Do not test against accounts or systems you do not have permission to use.

## Relevant boundaries

Feather uses the system WebKit engine and private WebKit APIs. It is not sandboxed. Optional agent access is disabled on normal launches and must be enabled for the current session. Browser extensions may request broad website access; review permissions before enabling them.

A DMG checksum confirms that a file matches the published checksum. It does not replace code signing, notarization, or review of the publisher. Release signing and notarization status must be stated in the release notes.
