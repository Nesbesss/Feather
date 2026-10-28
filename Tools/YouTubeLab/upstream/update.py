#!/usr/bin/env python3
"""Rebuild Feather's local upstream YouTube bundle from reviewed, hash-pinned inputs.

No npm installation, package lifecycle scripts, or third-party build tools run.
The generator consumes AdGuard's documented standalone CoreLibs distribution.
Use --offline after the first build; --check verifies reproducibility without writes.
Updating pins is an explicit review operation: there is intentionally no latest flag.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUTPUT = ROOT / 'Feather/Resources/YouTube/upstream'


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch_cached(name: str, url: str, expected: str, *, offline: bool, integrity=False) -> bytes:
    target = HERE / 'vendor' / name
    if target.exists():
        data = target.read_bytes()
    elif offline:
        raise RuntimeError(f'Missing offline input: {target}')
    else:
        with urllib.request.urlopen(url, timeout=45) as response:
            data = response.read()
    actual = ('sha512-' + base64.b64encode(hashlib.sha512(data).digest()).decode()) if integrity else sha256(data)
    if actual != expected:
        raise RuntimeError(f'Integrity mismatch for {name}; pinned source was not accepted')
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return data


def quoted_arguments(text: str) -> list[str]:
    """Strict parser for the reviewed AdGuard single/double-quoted argument list.

    Regex backslashes such as \? must survive; JavaScript/Python string eval is
    deliberately not used. Only escaped quote and escaped backslash are decoded.
    """
    values = []
    pos = 0
    while pos < len(text):
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos == len(text):
            break
        quote = text[pos]
        if quote not in "\"'":
            raise ValueError('Expected a quoted scriptlet argument')
        pos += 1
        value = []
        while pos < len(text):
            char = text[pos]
            pos += 1
            if char == quote:
                break
            if char == '\\' and pos < len(text) and text[pos] in (quote, '\\'):
                value.append(text[pos])
                pos += 1
            else:
                value.append(char)
        else:
            raise ValueError('Unterminated scriptlet argument')
        values.append(''.join(value))
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos < len(text):
            if text[pos] != ',':
                raise ValueError('Expected comma between scriptlet arguments')
            pos += 1
    return values


def selected_rules(lines: list[str], selected: list[int], library: dict) -> list[dict]:
    # Upstream old recovery scripts are explicitly excepted for non-Firefox.
    for old, exception in [(1020, 1025), (1021, 1026)]:
        assert lines[old-1].replace('#%#', '#@%#', 1) == lines[exception-1]
        assert old not in selected
    rules = []
    for line_number in selected:
        original = lines[line_number - 1]
        if original.startswith('!') or '#@%#' in original or '#%#' not in original:
            raise ValueError(f'Line {line_number} is not an active selected rule')
        domains, body = original.split('#%#', 1)
        path_prefix = None
        if domains.startswith('[$path=/tv]'):
            path_prefix = '/tv'
            domains = domains.removeprefix('[$path=/tv]')
        if not all(re.fullmatch(r'(?:[a-z]+\.)?(?:youtube(?:-nocookie)?|youtubekids)\.com', d) for d in domains.split(',')):
            raise ValueError(f'Unreviewed domain scope at line {line_number}')
        rule = {'id': f'adguard-base-L{line_number}', 'line': line_number,
                'domains': domains.split(','), 'pathPrefix': path_prefix,
                'sourceSHA256': sha256(original.encode()), 'source': original}
        if body.startswith('//scriptlet(') and body.endswith(')'):
            args = quoted_arguments(body[len('//scriptlet('):-1])
            name, *arguments = args
            if name not in library:
                raise ValueError(f'Unsupported scriptlet {name} at line {line_number}')
            rule.update(kind='scriptlet', name=name, args=arguments)
        elif body.startswith('(()=>') and body.endswith('();'):
            rule.update(kind='site-javascript', code=body)
        else:
            raise ValueError(f'Unreviewed executable rule form at line {line_number}')
        rules.append(rule)
    xhr = next(r for r in rules if r.get('name') == 'json-prune-xhr-response')
    assert '(?!.*(get_drm_license))' in xhr['args'][-1]
    return rules


def compatibility_patches(library: dict) -> list[dict]:
    """Patch known transport boundaries only, after checking complete upstream function hashes.

    The cached npm distribution and released source archive are never modified.
    Exact anchors plus the whole-function checks make an upstream change fail closed.
    """
    original_fetch = library['json-prune-fetch-response']
    original_xhr = library['json-prune-xhr-response']
    expected = {
        'json-prune-fetch-response': 'a4c5cb48a039ac62234074a0d77999ada3ed0644e7eec61ff8c280f2a27bcdcf',
        'json-prune-xhr-response': 'c0ee204ec7f4f730b9c8b1332c37245e2f54fb9674ef3c881e47f6f6e1609ba9',
    }
    for name, digest in expected.items():
        if sha256(library[name].encode()) != digest:
            raise RuntimeError(f'Compatibility patch requires review of changed upstream function: {name}')
    fetch_adapter = (HERE / 'patches/fetch-compat.js').read_text().strip()
    xhr_adapter = (HERE / 'patches/xhr-compat.js').read_text().strip()
    start = original_fetch.index(',fetchHandler={apply:async function(target,thisArg,args){')
    end = original_fetch.index(';window.fetch=new Proxy(window.fetch,fetchHandler)', start)
    get_start = original_fetch.index('fetchData=function(e,t){', start) + len('fetchData=')
    get_end = original_fetch.index('}(args,nativeRequestClone)', get_start) + 1
    get_data = original_fetch[get_start:get_end]
    match_start = original_fetch.index('if(!function(e,t,r){', start) + len('if(!')
    match_end = original_fetch.index('}(source,propsToMatch,fetchData))', match_start) + 1
    matcher = original_fetch[match_start:match_end]
    replacement = ',featherGetFetchData=' + get_data + ',featherMatchRequestProps=' + matcher + ',fetchHandler={apply:' + fetch_adapter + '}'
    library['json-prune-fetch-response'] = original_fetch[:start] + replacement + original_fetch[end:]
    start = original_xhr.index(',nativeOpen=window.XMLHttpRequest.prototype.open')
    end = original_xhr.rindex('}}).apply(this,updatedArgs)')
    replacement = ';(' + xhr_adapter + ')(source,propsToMatch,stack,featherNativeJSONParse,nativeStringify,pruneJsonValue,' + matcher + ');'
    library['json-prune-xhr-response'] = original_xhr[:start] + replacement + original_xhr[end:]
    return [
        {'id': 'FEATHER-AG251-FETCH-001', 'scriptlet': 'json-prune-fetch-response',
         'originalFunctionSHA256': expected['json-prune-fetch-response'],
         'patchedFunctionSHA256': sha256(library['json-prune-fetch-response'].encode()),
         'adapterSHA256': sha256(fetch_adapter.encode()),
         'reason': 'One native fetch; normalize URL matching; validate initial/final endpoint and MIME before body read; retain native stream/bodyUsed/clone state and corrected representation headers.'},
        {'id': 'FEATHER-AG251-XHR-001', 'scriptlet': 'json-prune-xhr-response',
         'originalFunctionSHA256': expected['json-prune-xhr-response'],
         'patchedFunctionSHA256': sha256(library['json-prune-xhr-response'].encode()),
         'adapterSHA256': sha256(xhr_adapter.encode()),
         'reason': 'Use the real XHR and native events/getters; rewrite only completed JSON/text responses with matching initial/final endpoint and MIME; preserve binary bytes and responseText exceptions.'},
    ]


def ad_signal_patch(library: dict, originals: dict) -> dict:
    """Observe successful ad-only mutations; never treat generic hit() as evidence."""
    expected = {
        'set-constant': 'a4d82fadcc8fff4840d7db491d8b1c8a0586510a9dba3cf561844cf14c0ec073',
        'json-prune': 'a634626c0522764fee22d355d1daa4a9187594f9f5e984a5916dad4c5dd9ea18',
        'json-prune-fetch-response': 'a4c5cb48a039ac62234074a0d77999ada3ed0644e7eec61ff8c280f2a27bcdcf',
        'json-prune-xhr-response': 'c0ee204ec7f4f730b9c8b1332c37245e2f54fb9674ef3c881e47f6f6e1609ba9',
    }
    def replace_once(text: str, anchor: str, replacement: str) -> str:
        if text.count(anchor) != 1:
            raise RuntimeError('Ad signal patch requires review of unexpected upstream structure')
        return text.replace(anchor, replacement, 1)
    for name, digest in expected.items():
        if sha256(originals[name].encode()) != digest:
            raise RuntimeError(f'Ad signal patch requires review of changed upstream function: {name}')
        text = library[name]
        if name == 'set-constant':
            text = replace_once(text, 'set(t){i(t)?s(t):this.factValue=t}',
                                'set(t){i(t)?s(t):(this.factValue=t,featherAdEvidence.mutation(e,d,t))}')
            text = replace_once(text, 'else n(u,d,!1,l)};',
                                'else n(u,d,!1,l)&&featherAdEvidence.mutation(e,d,l.factValue)};')
        else:
            # Own data descriptors avoid adding getter evaluation to pruning.
            text = replace_once(text, 's.base.splice(l,1)',
                '{const featherPrevious=featherAdEvidence.previous(s.base,s.prop),featherLength=featherAdEvidence.length(s.base);'
                's.base.splice(l,1);featherAdEvidence.spliced(e,s.base,s.prop,featherPrevious,featherLength)}')
            text = replace_once(text, 'else delete s.base[s.prop]',
                'else{const featherPrevious=featherAdEvidence.previous(s.base,s.prop);'
                'if(delete s.base[s.prop])featherAdEvidence.deleted(e,s.base,s.prop,featherPrevious)}')
            text = replace_once(text, 'else delete n.parent[n.key],markMutated()',
                'else{const featherPrevious=featherAdEvidence.previous(n.parent,n.key);'
                'if(delete n.parent[n.key])featherAdEvidence.deleted(source,n.parent,n.key,featherPrevious);markMutated()}')
            text = replace_once(text, 'r.splice(n,1),markMutated()',
                '(()=>{const featherPrevious=featherAdEvidence.previous(r,n),featherLength=featherAdEvidence.length(r);'
                'r.splice(n,1);featherAdEvidence.spliced(source,r,n,featherPrevious,featherLength);markMutated()})()')
        library[name] = text
    helper = (HERE / 'patches/ad-signal.js').read_text().strip()
    return {'id': 'FEATHER-AG251-ADSIGNAL-001',
            'originalFunctionSHA256': expected,
            'patchedFunctionSHA256': {name: sha256(library[name].encode()) for name in expected},
            'adapterSHA256': sha256(helper.encode()),
            'reason': 'Optional lexical callback only after confirmed nonempty ad-only suppression/removal; no signals for installs, reads, empty fields, unchanged responses or recovery. Transport events commit only after successful delivery preparation.'}


def generate(pins: dict, archive: bytes, filters: bytes, source_archive: bytes) -> dict[str, bytes]:
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as package:
        corelibs = json.load(package.extractfile('package/dist/scriptlets.corelibs.json'))
        license_text = package.extractfile('package/LICENSE').read()
    if corelibs['version'] != pins['scriptlets']['version']:
        raise RuntimeError('Unexpected CoreLibs scriptlet version')
    library = {name: item['scriptlet'] for item in corelibs['scriptlets'] for name in item['names']}
    originals = library.copy()
    patches = compatibility_patches(library)
    patches.append(ad_signal_patch(library, originals))
    lines = filters.decode().splitlines()
    rules = selected_rules(lines, pins['filters']['selectedLines'], library)
    names = sorted({rule['name'] for rule in rules if rule['kind'] == 'scriptlet'})
    version = 'adguard-' + corelibs['version'] + '-base-' + pins['filters']['commit'][:12] + '-scope2-transport1-signal1'
    js = [
        '/* Generated by Tools/YouTubeLab/upstream/update.py. DO NOT EDIT.',
        ' * AdGuard Scriptlets and selected AdGuard Filters: GPL-3.0.',
        ' * See LICENSE, SOURCE-NOTICES.md, manifest.json and source-rules.txt.',
        ' * Local executable resources only; no runtime remote-code download.',
        ' */',
        '(() => {',
        "  'use strict';",
        "  const canonicalHost = String(location.hostname || '').trim().toLowerCase().replace(/\\.+$/, '');",
        "  if (!/(^|\\.)(?:youtube(?:-nocookie)?|youtubekids)\\.com$/.test(canonicalHost)) return;",
        "  if (Object.prototype.hasOwnProperty.call(globalThis, '__featherYouTubeUpstream')) return;",
        '  const featherNativeJSONParse = JSON.parse;',
        (HERE / 'patches/ad-signal.js').read_text().strip(),
        '  const stats = {schemaVersion: 1, version: ' + json.dumps(version) + ', eligibleRules: 0, invokedRules: 0, failedRules: 0, failureRuleIDs: []};',
        "  Object.defineProperty(globalThis, '__featherYouTubeUpstream', {configurable: false, enumerable: false, get: () => ({...stats, failureRuleIDs: [...stats.failureRuleIDs]})});",
        "  const eligible = (domains, prefix) => domains.some(domain => canonicalHost === domain || canonicalHost.endsWith('.' + domain)) && (!prefix || location.pathname.startsWith(prefix));",
        "  const failure = id => {stats.failedRules++; if (stats.failureRuleIDs.length < 8) stats.failureRuleIDs.push(id);};",
        '  const functions = {',
    ]
    js.extend('    ' + json.dumps(name) + ': ' + library[name] + ',' for name in names)
    js.append('  };')
    for rule in rules:
        js += ['  // ' + rule['id'] + ': ' + rule['kind'],
               '  if (eligible(' + json.dumps(rule['domains']) + ', ' + json.dumps(rule['pathPrefix']) + ')) {',
               '    stats.eligibleRules++;', '    try {']
        if rule['kind'] == 'scriptlet':
            source = {'name': rule['name'], 'args': rule['args'], 'engine': 'corelibs',
                      'version': corelibs['version'], 'verbose': False,
                      'uniqueId': 'Feather-' + version + '-' + rule['id']}
            js.append('      functions[' + json.dumps(rule['name']) + '](' + json.dumps(source, ensure_ascii=True) + ', ' + json.dumps(rule['args'], ensure_ascii=True) + ');')
        else:
            js.append('      ' + rule['code'])
        js += ['      stats.invokedRules++;', '    } catch (_) {failure(' + json.dumps(rule['id']) + ');}', '  }']
    js += ['})();', '']
    script = '\n'.join(js).encode()
    manifest = {
        'schemaVersion': 1, 'version': version, 'wrapperScopeRevision': 2,
        'compatibilityPatches': patches,
        'injection': {'file': 'youtube-upstream.js', 'time': 'documentStart', 'world': 'page', 'allFrames': True,
                      'integration': 'Insert inside the native per-site policy gate; do not stack another pruning engine.'},
        'diagnostics': {'global': '__featherYouTubeUpstream', 'configurable': False, 'failureIDsLimit': 8,
                        'semantics': 'Invoked rules are attempted installations, not proven ad prevention. CoreLibs functions also catch some internal errors.'},
        'adInterventionSignal': {'lexicalCallback': '__FEATHER_AD_INTERVENTION__',
                                 'kinds': ['ad-data-suppressed', 'ad-data-removed'], 'maximumCallbacks': 1000000,
                                 'semantics': 'Evidence of nonempty known ad-data suppression/removal, not proof a video ad would have played. Conservative: raw site JavaScript/SSAP/skip paths are not counted.'},
        'scriptlets': pins['scriptlets'], 'filters': pins['filters'],
        'bundleSHA256': sha256(script), 'bundleBytes': len(script),
        'selectedRuleCount': len(rules), 'standaloneScriptletFunctions': names,
        'rules': [{k: v for k, v in r.items() if k not in ('code', 'source')} for r in rules],
        'platformSelection': {
            'environment': 'Feather WKWebView with CoreLibs scriptlets 2.5.1; non-Firefox, no native response-body rewriting.',
            'hostCanonicalization': 'Wrapper scope uses lowercase host with surrounding whitespace and trailing dots removed, matching the native policy. Selected rule text is unchanged; function compatibility/evidence patches are recorded separately.',
            'includedBrowserFallbackLines': [998, 999, 1000],
            'excludedFirefoxOnlyLines': [1007, 1010],
            'exceptedOldRecoveryLines': {'old': [1020, 1021], 'exceptions': [1025, 1026]},
            'shorts': 'Use modern library-backed line 1037; exclude legacy Safari line 1039 because vendored 2.5.1 exceeds the upstream >=2.2.7 requirement.',
            'tvPathAdaptation': 'Line 1013 $path=/tv is restricted to pathname prefix /tv.'},
        'notImplemented': [
            {'lines': [976, 978, 979, 980, 981, 982, 1003], 'reason': 'Native document/network JSON prune/replace requires response-body interception; page script fallbacks are included where upstream supplies them.'},
            {'lines': [1012, 1079], 'reason': 'Network/CDN blocking is not part of this JavaScript bundle. No broad googlevideo rule is generated.'},
            {'reason': 'Upstream frame workaround line 1015 copies fetch/Request only; no claim to defeat JSON.parse clean-frame recovery or every sandbox configuration.'},
            {'reason': 'Includes current upstream SSAP/Promise decoder interventions; universal UMP/SABR/SSAP efficacy is unproven and requires native live testing.'}],
        'sourceArchiveSHA256': sha256(source_archive),
        'noRuntimeRemoteCode': True,
    }
    extract = '\n'.join(f'! Upstream source line {i+1}\n{line}' for i, line in enumerate(lines) if 959 <= i <= 1079) + '\n'
    selected = '\n'.join('! ' + r['id'] + '\n' + r['source'] for r in rules) + '\n'
    notice = f'''# Bundled upstream YouTube resources

Generated resource version: `{version}`.

AdGuard Scriptlets and AdGuard Filters are copyright their respective authors and contributors and are distributed under GPL-3.0. The full license is in `LICENSE`. Original filter JavaScript and pruning algorithms are retained; Feather adds domain/path selection, invocation and bounded diagnostic wrappers. Two scriptlet transport boundaries and conservative ad-only mutation notification points are modified by the explicit patches below. Path/host-scope adaptations are recorded in the manifest.

- Scriptlet package: `@adguard/scriptlets@{corelibs['version']}`, npm integrity `{pins['scriptlets']['integrity']}`.
- Package archive: {pins['scriptlets']['tarball']}
- Scriptlet source: https://github.com/AdguardTeam/Scriptlets/tree/{pins['scriptlets']['sourceCommit']}
- Filter source: {pins['filters']['repository']}/blob/{pins['filters']['commit']}/{pins['filters']['path']}
- `source-rules.txt` retains each selected filter exactly. `source-context.txt` includes disabled rules, exceptions and platform hints around the selection.
- `FEATHER-AG251-FETCH-001` replaces the fetch boundary to preserve response/clone/bodyUsed behavior, normalize URL inputs, avoid duplicate network requests, and bypass unrelated redirects/non-JSON transports before reading a body.
- `FEATHER-AG251-XHR-001` replaces the forged-XHR boundary with guarded native response getters. Binary responses, native events, status/header getters and responseText exceptions retain native behavior.
- `FEATHER-AG251-ADSIGNAL-001` adds optional lexical `__FEATHER_AD_INTERVENTION__(kind)` notification after successful suppression/removal of nonempty known ad metadata or explicit feed/Shorts ad items. Installation, getter reads, empty/unchanged data and recovery mutations stay silent. Fetch/XHR notifications are staged until the modified response is prepared successfully. This proves an ad-data intervention, not that a video ad would have played; raw site-JavaScript/SSAP interventions are conservatively uncounted. No global debug hook or response/URL/video payload is sent.
- Each patch checks the complete original function SHA-256 before replacement. Original/patched function and adapter hashes appear in `manifest.json`. The readable adapter sources are in `Tools/YouTubeLab/upstream/patches/`; cached upstream inputs remain unchanged.
- The reproducible generator, pins, verified npm archive, upstream source archive and filter snapshot are in `Tools/YouTubeLab/upstream/` in the Feather source tree. Rebuild using `python3 Tools/YouTubeLab/upstream/update.py --offline`.

The Scriptlets public repository is a mirror of the upstream development repository, as documented in its README. The source version here is the released v2.5.1 tag, not the later mirror HEAD. No upstream branding endorsement is implied. License labels and provenance are recorded here without interpreting the obligations of another distribution.

There is no runtime arbitrary remote-code loading, filter-list parser, broad video-CDN block, native response-body interception, or guarantee that ads are prevented. The selected current recovery/request-context scripts change page-native behavior and need playback regression testing. The manifest enumerates omitted rules and platform choices.
'''
    return {'youtube-upstream.js': script,
            'manifest.json': (json.dumps(manifest, indent=2) + '\n').encode(),
            'source-rules.txt': selected.encode(), 'source-context.txt': extract.encode(),
            'LICENSE': license_text, 'SOURCE-NOTICES.md': notice.encode()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--check', action='store_true', help='Verify outputs byte-for-byte without replacing them')
    args = parser.parse_args()
    pins = json.loads((HERE / 'pins.json').read_text())
    s, f = pins['scriptlets'], pins['filters']
    archive = fetch_cached(f'scriptlets-{s["version"]}.tgz', s['tarball'], s['integrity'], offline=args.offline, integrity=True)
    filters = fetch_cached(f'adguard-specific-{f["commit"]}.txt', f['url'], f['sha256'], offline=args.offline)
    source = fetch_cached(f'scriptlets-{s["version"]}-source.tar.gz', s['sourceArchive'], s['sourceArchiveSHA256'], offline=args.offline)
    outputs = generate(pins, archive, filters, source)
    if args.check:
        changed = [name for name, data in outputs.items() if not (OUTPUT / name).exists() or (OUTPUT / name).read_bytes() != data]
        if changed:
            raise RuntimeError('Generated outputs differ: ' + ', '.join(changed))
    else:
        OUTPUT.mkdir(parents=True, exist_ok=True)
        for name, data in outputs.items():
            (OUTPUT / name).write_bytes(data)
    print(json.dumps({'mode': 'check' if args.check else 'build', 'output': str(OUTPUT),
                      'bundleBytes': len(outputs['youtube-upstream.js']), 'sha256': sha256(outputs['youtube-upstream.js'])}))


if __name__ == '__main__':
    main()
