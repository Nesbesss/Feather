# Study Tools for Magister

Bundled from [QkeleQ10/Study-Tools](https://github.com/QkeleQ10/Study-Tools), version 3.16.3.

Upstream commit: `dcfd27b451f4aeb13f857fbed80133973b209816` (2026-10-19).

Chrome Web Store extension ID: `hacjodpccmeoocakiahjfndppdeallak`.

The upstream MIT license and copyright notice are preserved in `LICENSE`. The JavaScript, styles, translations, icons, and prebuilt Vue configuration panel are included locally. Development dependencies, source-control metadata, and the unused Firefox background script are omitted.

Feather runs this extension with WebKit's native `WKWebExtension` APIs. The files are unchanged from upstream except for these changes to `src/service-worker.js`:

- Register the credential request listener once, synchronously when the worker starts, so requests can wake a suspended WebKit worker.
- Await session storage access before loading credentials or processing captured requests. Keep authentication tokens in memory-backed `storage.session`.
- Match HTTP header names without case sensitivity and accept requests without a header array.
- Remove the Chrome-specific keepalive interval and redundant worker activation/startup listener registrations.
- Remove each temporary request-completion listener and its timeout after the first result. Only respond to completion events from the requesting tab.

`storage.sync` settings are stored by Feather's WebKit extension controller within the corresponding browser space. Chrome account synchronization is not provided by Feather.

To update, replace the runtime resources from a reviewed upstream commit, preserve `LICENSE`, reapply the changes above, update this notice, and run `node --test Tools/StudyToolsLab/service-worker.test.mjs` from the repository root.
