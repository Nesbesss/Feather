# Local upstream YouTube bundle

Frozen resource version: **`adguard-2.5.1-base-f404d017ca1d-scope2-transport1-signal1`**, 133,098 bytes, SHA-256 **`b7fcaee290fed8d48c689a03e3434466881f1eba775f538a234806730127cb1d`**. This identifies the generated JavaScript alone; a composed production script also includes Feather's policy/coordinator source and can have a different hash. Earlier experimental hashes remain historical evidence and must not be relabeled as this revision.

## Rebuild and verify

`python3 Tools/YouTubeLab/upstream/update.py` verifies pinned npm/source/filter inputs, saves the verified inputs in `vendor/`, and generates `Feather/Resources/YouTube/upstream/`. No npm install or package scripts execute. Reproduce offline with:

```sh
python3 Tools/YouTubeLab/upstream/update.py --offline --check
node --check Feather/Resources/YouTube/upstream/youtube-upstream.js
node Tools/YouTubeLab/upstream/smoke.mjs
node Tools/YouTubeLab/upstream/transport-contracts.mjs
node Tools/YouTubeLab/upstream/ad-signal-contracts.mjs
```

The runtime file is a standalone IIFE: inject at document start in `WKContentWorld.page`, all frames, **inside Feather's per-site policy gate**. It installs only on the selected YouTube-family domains. It is an alternative to another player-data pruning engine; do not stack both while evaluating it. The native integration may insert these bytes at its `/*__FEATHER_UPSTREAM__*/` marker.

`__featherYouTubeUpstream` is a nonconfigurable getter returning bounded version/attempt/failure diagnostics. Invoked rules are attempted installations; some upstream helpers catch their own errors, so zero reported failures is not proof that every hook installed or that an ad was blocked.

The generated manifest records every selected rule, its original line/hash/scope, non-Firefox exception resolution, modern Shorts choice, the narrow `get_drm_license` exclusion and unsupported native response-body modifiers. Raw current upstream recovery/request-context/streaming code is included alongside the five standalone scriptlet implementations. No broad video-CDN block is generated. AdGuard's included clean-frame workaround copies `fetch`/`Request`; it does not establish universal sandbox/`JSON.parse` bypass protection. Native playback and transport tests remain necessary.

Two audited compatibility adapters are applied to the released package's fetch/XHR boundaries. They retain the upstream pruning algorithms and current site rules while correcting transport regressions found in native WebKit tests. `patches/fetch-compat.js` ensures a single native request, initial/final endpoint and MIME gating, URL-input matching, native body-use/clone state, and corrected rewritten-body headers. `patches/xhr-compat.js` retains the original request, events, status/header getters and binary data; only completed matching JSON/text responses are exposed through guarded native getters. The generator checks the complete upstream function hashes before patching; the generated manifest records original/patched function hashes and readable-adapter hashes. The original npm and source archives are unchanged.

| Patch | Compatibility boundary |
| --- | --- |
| `FEATHER-AG251-FETCH-001` | Matches the initial request against its upstream rule and limits both endpoints to known YouTube player/next/get_watch/watch/playlist response paths. A same-family player-to-next redirect can be pruned; foreign hosts and unrelated final paths pass through. MIME checks precede cloning/reading; event streams, binary types, HTML, NDJSON and missing MIME pass through. A parser captured before upstream JSON hooks makes unchanged-body detection reliable. Rewritten responses omit stale length/encoding headers and retain dynamic native body use and clone independence. |
| `FEATHER-AG251-XHR-001` | Uses the original XHR rather than creating a replacement request or synthesizing events. Native getter invocation preserves type/brand errors; only completed successful JSON/text responses with approved MIME and endpoints can be pruned. Arraybuffer/blob data, status/header APIs and native request/event behavior remain native. |
| `FEATHER-AG251-ADSIGNAL-001` | Adds a conservative optional lexical `__FEATHER_AD_INTERVENTION__(kind)` callback at successful known ad-data mutation points. Only nonempty `adPlacements`/`adSlots`/`playerAds`, explicit feed renderers or true Shorts ad items qualify. Constant getter reads, empty fields, rule installation, unchanged data, recovery changes and failed response preparation stay silent. No global debug hook, URL, response payload or video ID is sent. |

The adapters and mutation instrumentation are explicit Feather changes. The selected filter source/raw site rules and pruning algorithms remain upstream-derived; the transport wrappers, notification points and canonical host scope are recorded independently. This distinction matters when diagnosing differences from AdGuard itself.

The frozen revision passed **10 Node smoke checks**, **23 focused Node transport contracts** and **18 ad-signal contracts** using the commands above. The transport contracts cover string/URL/Request input, one network call, rejection behavior, bodyUsed, clones and metadata, known and unrelated redirects, unclosed SSE pass-through, unsupported MIME, earlier JSON.parse-hook interaction, native XHR text/JSON behavior, binary identity and responseText exceptions. Ad-signal contracts cover nonempty initial and late constant suppression, property/array/JSONPath removals, quiet reads/empty/unchanged/recovery cases, optional/throwing callbacks, descriptor-observation failures that must not abort pruning, and discarding staged notifications when response preparation fails. Each test realm uses its own Response subclass so upstream prototype wrappers cannot contaminate later fixtures. These are integration contracts in a Node realm, not native browser measurements or ad-prevention trials. Use the separate native policy/transport fixtures and actual-app observations as distinct evidence. A fixture that intentionally reproduces a bypass is not a successful prevention case.

The embedding coordinator may declare `__FEATHER_AD_INTERVENTION__` in its enclosing lexical scope before inserting the bundle. The only arguments are the literal kinds `ad-data-suppressed` and `ad-data-removed`; at most 1,000,000 callbacks are delivered per injected realm. Callback errors cannot interrupt the original intervention. Fetch/XHR mutations are staged synchronously and only committed once the modified response is prepared. The signal establishes an ad-data intervention, not that a particular video ad would otherwise have played. Raw upstream site-JavaScript/SSAP changes are conservatively uncounted; notification coverage is intentionally narrower than protection coverage.

To update, explicitly review a new released package version and filter commit, then edit `pins.json` with independently verified hashes and reviewed line selection. The generator intentionally fails on changed inputs or unrecognized executable syntax. Re-evaluate platform hints/exceptions; do not increment line numbers mechanically. Rebuild, run the commands above, review source and manifest changes, then run native fixture and live paired-control tests before changing a shipped snapshot. Runtime code never fetches new executable rules.

The GPL-3.0 license, exact selected/context filter source and notices are generated beside the runtime file. `vendor/` retains the npm distribution, its corresponding released source archive, and the hash-pinned filter snapshot. The public source repository is a mirror; the manifest distinguishes the released package source commit from later mirror HEAD.

`adblock-rust` remains a larger engine option for general filtering, but integrating its parser does not itself execute the response-editing and raw site rules above. This package-first path provides concrete maintained scriptlet implementations immediately; Feather still owns native gating, rule-list coverage, frame integration, rollback and verification.

## Passive actual-app observations

The actual Feather benchmark runner supports the explicit argument pair **`-BenchmarkYouTube YES`**. A persisted defaults value alone does not enable this probe, and it is never created in an ordinary launch without benchmark URL/report arguments. For an already built app, an invocation has this shape:

```sh
/path/to/Feather.app/Contents/MacOS/Feather \
  -BenchmarkURLs /tmp/feather-youtube-urls.txt \
  -BenchmarkReport /tmp/feather-actual-youtube.json \
  -BenchmarkInterval 6 -BenchmarkSettle 60 -BenchmarkYouTube YES
```

The URL list contains one ordinary page URL per line. The existing benchmark opens foreground tabs, uses unsaved session/nonpersistent website storage, writes its report after the settling interval and quits. Normal Feather settings, native rule readiness, consent handling and autoplay requirements still apply. A real trusted user/CUA click can start playback; this probe issues no play/pause/seek/mute/click/consent commands, network requests, page-state writes or autoplay-policy overrides.

The optional `youtubeObservations` array is sampled alongside memory every two seconds. It targets a live main YouTube/nocookie page or its tracked YouTube media embed; at most eight tabs are selected per sample, with the active tab first. In-flight captures coalesce to the latest pending sample. The final queued capture is awaited before report writing, with a two-second per-evaluation deadline. At most 20,000 observations are retained. A timeout or missing/stale frame is recorded as a capture status, not successful playback.

Each observation contains elapsed `t`, local `tabID`, `frame` (`main`/`mediaEmbed`) and `captureStatus`, plus optional bounded `videoID`, `currentTime`, `duration`, `paused`, `readyState`, media-error **code**, `adShowing`, playability status, counts for `adPlacements`/`adSlots`/`playerAds`, coordinator/upstream versions, upstream eligible/invoked/failed-rule counts, `adInterventions`, `catchNoticesSent`, and `policyStampExposed` (expected false). Notification attempts do not establish that a native toast was presented. It does not record request URLs, cookies, media tokens, response bodies, error messages or stamp values. Existing benchmark fields such as the caller-supplied URL list remain part of the general report; review them separately before sharing it.

Interpret the samples together: absent ad UI or zero ad fields can accompany paused, unready, unavailable or stalled media. Upstream invocation counters measure attempted installation, and skip/repair counters in the coordinator describe interventions rather than confirmed prevention. Only matched control sessions with observed ad opportunities and sustained main-content playback can support a bounded live efficacy statement; even then the account, region, runtime, resource/composed-script hashes and sample size limit the conclusion.
