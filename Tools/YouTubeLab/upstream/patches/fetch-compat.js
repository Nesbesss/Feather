async function featherFetchBoundary(target, thisArg, args) {
  // FEATHER-AG251-FETCH-001: transport boundary only; upstream pruner is retained.
  const scopedURL = raw => {
    if (typeof raw !== 'string' || raw === '') return null;
    try {
      const url = new URL(raw, document.baseURI || location.href);
      const host = url.hostname.toLowerCase().replace(/\.+$/, '');
      const knownPath = /^\/youtubei\/v\d+\/(?:player|next|get_watch)$/.test(url.pathname)
        || (url.pathname === '/watch' && (url.searchParams.has('v') || url.searchParams.has('t')))
        || (url.pathname === '/playlist' && url.searchParams.has('list'));
      if (!/^https?:$/.test(url.protocol)
        || !/(^|\.)(?:youtube(?:-nocookie)?|youtubekids)\.com$/.test(host)
        || !knownPath || url.href.includes('get_drm_license')) return null;
      return url.href;
    } catch (_) { return null; }
  };
  const jsonContent = response => /^(?:application\/(?:[a-z0-9!#$&^_.+-]+\+)?json|text\/(?:json|plain))(?:\s*;|$)/i
    .test(response.headers.get('content-type') || '');
  let fetchData;
  try {
    const input = args[0];
    const isURL = typeof URL === 'function' && (input instanceof URL || Object.prototype.toString.call(input) === '[object URL]');
    const matchingArgs = isURL ? [String(input), args[1]] : args;
    fetchData = featherGetFetchData(matchingArgs, nativeRequestClone);
    const initialURL = scopedURL(fetchData.url);
    if (!initialURL) return Reflect.apply(target, thisArg, args);
    fetchData.url = initialURL;
    if (!featherMatchRequestProps(source, propsToMatch, fetchData)) return Reflect.apply(target, thisArg, args);
  } catch (_) { return Reflect.apply(target, thisArg, args); }

  // Exactly one call. A network rejection retains native behavior; never retry it.
  const original = await Reflect.apply(target, thisArg, args);
  const finalURL = scopedURL(original.url);
  if (!finalURL || !original.ok || original.body === null || !jsonContent(original)) return original;

  try {
    // Read a clone only after transport/type validation. SSE/binary/missing MIME
    // types and unrelated redirects return above without touching the body.
    const clone = nativeResponseClone.call(original);
    const text = await clone.text();
    // Captured before this bundle installs JSON.parse proxies, so unchanged
    // detection cannot mistake another upstream pruner's edits for native data.
    const value = featherNativeJSONParse(text);
    const before = nativeObjects.nativeStringify(value);
    const evidence = featherAdEvidence.capture(() => nativeObjects.nativeStringify(pruneJsonValue(value)));
    const clean = evidence.value;
    if (clean === before) return original;

    const headers = new Headers(original.headers);
    headers.delete('content-length');
    headers.delete('content-encoding');
    const replacement = new Response(clean, {status: original.status, statusText: original.statusText, headers});
    const metadata = (response, from) => {
      Object.defineProperties(response, {
        url: {value: from.url, configurable: true},
        type: {value: from.type, configurable: true},
        redirected: {value: from.redirected, configurable: true},
        clone: {configurable: true, writable: true, value: function () {
          // Clone and bodyUsed retain native stream state and independence.
          return metadata(nativeResponseClone.call(this), this);
        }}
      });
      return response;
    };
    const result = metadata(replacement, original);
    hit(source);
    evidence.commit();
    return result;
  } catch (_) {
    // Parsing/cloning/rewriting failures do not consume the original response.
    return original;
  }
}
