# Bundled upstream YouTube resources

Generated resource version: `adguard-2.5.1-base-f404d017ca1d-scope2-transport1-signal1`.

AdGuard Scriptlets and AdGuard Filters are copyright their respective authors and contributors and are distributed under GPL-3.0. The full license is in `LICENSE`. Original filter JavaScript and pruning algorithms are retained; Feather adds domain/path selection, invocation and bounded diagnostic wrappers. Two scriptlet transport boundaries and conservative ad-only mutation notification points are modified by the explicit patches below. Path/host-scope adaptations are recorded in the manifest.

- Scriptlet package: `@adguard/scriptlets@2.5.1`, npm integrity `sha512-008B4qm6mXU4mqHOl1HE/jfRa0D/LUX2Lx4k00G45csiBF/fnIGzVivPsT1Q+Uhp9C+zj5tKoekkL39W8HqjzA==`.
- Package archive: https://registry.npmjs.org/@adguard/scriptlets/-/scriptlets-2.5.1.tgz
- Scriptlet source: https://github.com/AdguardTeam/Scriptlets/tree/920b92324bac850eecaa07589e67d5ff8bcee037
- Filter source: https://github.com/AdguardTeam/AdguardFilters/blob/f404d017ca1d47ff8b1bf0c3dd41b9c258b3ca7a/BaseFilter/sections/specific.txt
- `source-rules.txt` retains each selected filter exactly. `source-context.txt` includes disabled rules, exceptions and platform hints around the selection.
- `FEATHER-AG251-FETCH-001` replaces the fetch boundary to preserve response/clone/bodyUsed behavior, normalize URL inputs, avoid duplicate network requests, and bypass unrelated redirects/non-JSON transports before reading a body.
- `FEATHER-AG251-XHR-001` replaces the forged-XHR boundary with guarded native response getters. Binary responses, native events, status/header getters and responseText exceptions retain native behavior.
- `FEATHER-AG251-ADSIGNAL-001` adds optional lexical `__FEATHER_AD_INTERVENTION__(kind)` notification after successful suppression/removal of nonempty known ad metadata or explicit feed/Shorts ad items. Installation, getter reads, empty/unchanged data and recovery mutations stay silent. Fetch/XHR notifications are staged until the modified response is prepared successfully. This proves an ad-data intervention, not that a video ad would have played; raw site-JavaScript/SSAP interventions are conservatively uncounted. No global debug hook or response/URL/video payload is sent.
- Each patch checks the complete original function SHA-256 before replacement. Original/patched function and adapter hashes appear in `manifest.json`. The readable adapter sources are in `Tools/YouTubeLab/upstream/patches/`; cached upstream inputs remain unchanged.
- The reproducible generator, pins, verified npm archive, upstream source archive and filter snapshot are in `Tools/YouTubeLab/upstream/` in the Feather source tree. Rebuild using `python3 Tools/YouTubeLab/upstream/update.py --offline`.

The Scriptlets public repository is a mirror of the upstream development repository, as documented in its README. The source version here is the released v2.5.1 tag, not the later mirror HEAD. No upstream branding endorsement is implied. License labels and provenance are recorded here without interpreting the obligations of another distribution.

There is no runtime arbitrary remote-code loading, filter-list parser, broad video-CDN block, native response-body interception, or guarantee that ads are prevented. The selected current recovery/request-context scripts change page-native behavior and need playback regression testing. The manifest enumerates omitted rules and platform choices.
