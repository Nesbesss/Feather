function featherXHRBoundary(source, propsToMatch, stack, nativeParse, nativeStringify, pruneJsonValue, matchRequestProps) {
  // FEATHER-AG251-XHR-001: keep the real request, events, response types and getters.
  const prototype = window.XMLHttpRequest.prototype;
  const requests = new WeakMap();
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
  const jsonContent = xhr => /^(?:application\/(?:[a-z0-9!#$&^_.+-]+\+)?json|text\/(?:json|plain))(?:\s*;|$)/i
    .test(xhr.getResponseHeader('content-type') || '');
  const nativeOpen = prototype.open;
  prototype.open = new Proxy(nativeOpen, {apply(target, receiver, args) {
    // Native validation and state reset happen before our bookkeeping.
    const result = Reflect.apply(target, receiver, args);
    requests.delete(receiver);
    try {
      const input = args[1];
      const raw = typeof input === 'string' ? input
        : typeof URL === 'function' && (input instanceof URL || Object.prototype.toString.call(input) === '[object URL]') ? String(input) : null;
      const url = scopedURL(raw);
      const data = {method: String(args[0]), url, async: args[2] !== false};
      if (url && matchRequestProps(source, propsToMatch, data)) {
        requests.set(receiver, {data, stackAllowed: !stack, cached: false, text: null, json: null});
      }
    } catch (_) { /* Unknown/coercible input keeps native behavior. */ }
    return result;
  }});
  if (stack) {
    prototype.send = new Proxy(prototype.send, {apply(target, receiver, args) {
      const record = requests.get(receiver);
      if (record) record.stackAllowed = matchStackTrace(stack, new Error().stack || '');
      return Reflect.apply(target, receiver, args);
    }});
  }
  for (const key of ['response', 'responseText']) {
    const descriptor = Object.getOwnPropertyDescriptor(prototype, key);
    if (!descriptor?.get || !descriptor.configurable) continue;
    Object.defineProperty(prototype, key, {...descriptor, get() {
      // Calling the native getter first preserves brand checks and native
      // InvalidStateError from responseText on json/arraybuffer/blob responses.
      const nativeValue = Reflect.apply(descriptor.get, this, []);
      const record = requests.get(this);
      if (!record?.stackAllowed || this.readyState !== 4 || this.status < 200 || this.status >= 300) return nativeValue;
      const type = this.responseType;
      if (type !== '' && type !== 'text' && type !== 'json') return nativeValue;
      const finalURL = scopedURL(this.responseURL);
      if (!finalURL || !jsonContent(this)) return nativeValue;
      if (record.cached) return type === 'json' ? record.json : record.text;
      try {
        if (type === 'json' && (key !== 'response' || nativeValue === null || typeof nativeValue !== 'object')) return nativeValue;
        if (type !== 'json' && typeof nativeValue !== 'string') return nativeValue;
        const evidence = featherAdEvidence.capture(() => {
          if (type === 'json') record.json = pruneJsonValue(nativeValue);
          else {
            const value = nativeParse(nativeValue);
            const before = nativeStringify(value);
            const clean = nativeStringify(pruneJsonValue(value));
            record.text = clean === before ? nativeValue : clean;
          }
        });
        record.cached = true;
        hit(source);
        evidence.commit();
        return type === 'json' ? record.json : record.text;
      } catch (_) { return nativeValue; }
    }});
  }
}
