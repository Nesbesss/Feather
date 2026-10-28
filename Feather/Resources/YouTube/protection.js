/* Feather YouTube protection coordinator, version 2026.10.25.4.
 * Native code supplies __FEATHER_POLICY__ before this bundled source.
 * Response/transport interventions come from the separately attributed,
 * pinned AdGuard bundle inserted at the marker below; no overlapping engine.
 */
(() => {
  'use strict';
  const policy = typeof __FEATHER_POLICY__ === 'object' && __FEATHER_POLICY__;
  if (!policy || policy.enabled !== true || policy.topLevelAllowed === false) return;
  const canonical = host => String(host || '').trim().toLowerCase().replace(/\.+$/, '');
  const youtubeHost = host => /(^|\.)youtube(?:-nocookie)?\.com$/.test(canonical(host));
  const allowed = host => Array.isArray(policy.allowlistedHosts) && policy.allowlistedHosts.some(value => {
    const rule = canonical(value);
    return rule !== '' && (host === rule || host.endsWith('.' + rule));
  });
  let host = canonical(location.hostname);
  // Initial about:blank/srcdoc children inherit their parent's origin, but may
  // not receive a WebKit document-start callback. Never cross an origin here.
  if (!host && /^about:(?:blank|srcdoc)(?:[?#].*)?$/.test(location.href)) {
    try { host = canonical(parent.location.hostname); } catch (_) {}
  }
  if (!youtubeHost(host) || allowed(host)) return;
  if (Object.hasOwn(globalThis, '__featherYouTubeProtection')) return;
  const stats = { version: '2026.10.25.4', frameRepairs: 0, repairFailures: 0,
    skipClicks: 0, adCatches: 0, catchNotices: 0, cosmeticInstalled: false };
  const increment = key => { stats[key] = Math.min(stats[key] + 1, 1000000); };
  Object.defineProperty(globalThis, '__featherYouTubeProtection', {
    configurable: false,
    get: () => Object.freeze({ ...stats, upstream: globalThis.__featherYouTubeUpstream || null })
  });

  // The audited upstream signal reports confirmed nonempty ad-data removal or
  // suppression, rather than installation/read hits. Keep the callback lexical:
  // no page-callable debug API, URLs, response data or arbitrary toast text.
  let lastCatchNotice = -Infinity, pendingHiddenCatch = null, pendingCatchTimer = 0, feedbackActive = true;
  const clearPendingCatch = () => {
    pendingHiddenCatch = null;
    clearTimeout(pendingCatchTimer);
    pendingCatchTimer = 0;
  };
  const postCatchNotice = () => {
    // Coalesce synchronous mutation bursts only. Native delivery owns the
    // per-video cooldown and commits it after a notice was actually readable.
    if (!feedbackActive || document.hidden || performance.now() - lastCatchNotice < 250) return false;
    try {
      const handler = globalThis.webkit?.messageHandlers?.featherYouTubeAdCatch;
      if (typeof handler?.postMessage !== 'function') return false;
      handler.postMessage({ version: 1, event: 'adCaught' });
      lastCatchNotice = performance.now();
      increment('catchNotices');
      return true;
    } catch (_) { /* UI feedback must never interrupt playback protection. */ }
    return false;
  };
  const flushHiddenCatch = () => {
    if (!pendingHiddenCatch) return;
    if (!feedbackActive || performance.now() >= pendingHiddenCatch.monotonicDeadline
        || Date.now() >= pendingHiddenCatch.wallDeadline) { clearPendingCatch(); return; }
    if (document.hidden) return;
    const wait = 250 - (performance.now() - lastCatchNotice);
    if (wait > 0) {
      clearTimeout(pendingCatchTimer);
      pendingCatchTimer = setTimeout(() => { pendingCatchTimer = 0; flushHiddenCatch(); }, wait);
      return;
    }
    clearPendingCatch();
    postCatchNotice();
  };
  const __FEATHER_AD_INTERVENTION__ = () => {
    increment('adCatches');
    if (!feedbackActive) return;
    if (document.hidden) {
      // New documents may suppress their initial ad data before tab attachment.
      // Retain only recent real evidence; either clock can expire it.
      clearPendingCatch();
      pendingHiddenCatch = { monotonicDeadline: performance.now() + 6000, wallDeadline: Date.now() + 6000 };
      return;
    }
    if (postCatchNotice()) clearPendingCatch();
  };
  document.addEventListener('visibilitychange', flushHiddenCatch);
  addEventListener('pagehide', () => { feedbackActive = false; clearPendingCatch(); });
  addEventListener('pageshow', () => { feedbackActive = true; });

  /*__FEATHER_UPSTREAM__*/

  // Close the clean-native escape hatch synchronously, before a page can read
  // functions from a newly inserted same-origin blank frame. Accessing an
  // arbitrary cross-origin WindowProxy must retain native security behavior.
  const repaired = new WeakMap();
  function repairRealm(child) {
    if (!child || child === globalThis) return;
    try {
      if (!/^about:(?:blank|srcdoc)(?:[?#].*)?$/.test(child.location.href)) return;
      const documentIdentity = child.document;
      if (documentIdentity.defaultView !== child) return;
      const functions = ['fetch', 'Request', 'XMLHttpRequest'].filter(name => typeof globalThis[name] === 'function');
      if (repaired.get(child) === documentIdentity
          && functions.every(name => child[name] === globalThis[name])
          && ['parse', 'stringify'].every(name => child.JSON[name] === JSON[name])) return;
      // Assign only functions already protected by the upstream pipeline.
      // The child's JSON object/other APIs remain its own realm's objects.
      let successful = true;
      for (const name of functions) {
        try {
          child[name] = globalThis[name];
          if (child[name] !== globalThis[name]) { successful = false; increment('repairFailures'); }
        } catch (_) { successful = false; increment('repairFailures'); }
      }
      for (const name of ['parse', 'stringify']) {
        try {
          child.JSON[name] = JSON[name];
          if (child.JSON[name] !== JSON[name]) { successful = false; increment('repairFailures'); }
        } catch (_) { successful = false; increment('repairFailures'); }
      }
      if (successful) { repaired.set(child, documentIdentity); increment('frameRepairs'); }
    } catch (_) { /* A foreign frame keeps its native access boundary. */ }
  }
  const framePrototype = globalThis.HTMLIFrameElement?.prototype;
  if (framePrototype) {
    for (const name of ['contentWindow', 'contentDocument']) {
      const descriptor = Object.getOwnPropertyDescriptor(framePrototype, name);
      if (!descriptor?.get || !descriptor.configurable) continue;
      try {
        Object.defineProperty(framePrototype, name, { ...descriptor, get() {
          const result = Reflect.apply(descriptor.get, this, []);
          repairRealm(name === 'contentWindow' ? result : result?.defaultView);
          return result;
        } });
      } catch (_) { increment('repairFailures'); }
    }
  }
  function framesIn(node) {
    if (!node || typeof node !== 'object') return [];
    if (node.nodeType === 1 && node.localName === 'iframe') return [node];
    return typeof node.querySelectorAll === 'function' ? [...node.querySelectorAll('iframe')] : [];
  }
  function repairFrames(frames) {
    for (const frame of frames) {
      try { repairRealm(frame.contentWindow); } catch (_) {}
    }
  }
  // WindowProxy identity survives navigation. Capture the child's load before
  // page load handlers can recover fresh natives through window.frames[index].
  document.addEventListener('load', event => {
    if (event.target?.localName === 'iframe') repairFrames([event.target]);
  }, true);
  if (typeof globalThis.open === 'function') {
    try {
      globalThis.open = new Proxy(globalThis.open, { apply(target, receiver, args) {
        const child = Reflect.apply(target, receiver, args);
        repairRealm(child);
        return child;
      } });
    } catch (_) { increment('repairFailures'); }
  }
  // Collect before insertion too: a DocumentFragment becomes empty on append.
  for (const name of ['appendChild', 'insertBefore', 'replaceChild']) {
    const original = Node.prototype[name];
    try {
      Node.prototype[name] = new Proxy(original, { apply(target, receiver, args) {
        const frames = framesIn(args[0]);
        const result = Reflect.apply(target, receiver, args);
        repairFrames(frames);
        return result;
      } });
    } catch (_) { increment('repairFailures'); }
  }
  for (const prototype of [Element.prototype, globalThis.DocumentFragment?.prototype]) {
    if (!prototype) continue;
    for (const name of ['append', 'prepend', 'replaceChildren']) {
      const original = prototype[name];
      if (typeof original !== 'function') continue;
      try {
        prototype[name] = new Proxy(original, { apply(target, receiver, args) {
          const frames = args.flatMap(framesIn);
          const result = Reflect.apply(target, receiver, args);
          repairFrames(frames);
          return result;
        } });
      } catch (_) { increment('repairFailures'); }
    }
  }
  // HTML insertion can be followed immediately by window.frames[index] access.
  for (const name of ['innerHTML', 'outerHTML']) {
    const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, name);
    if (!descriptor?.set || !descriptor.configurable) continue;
    try {
      Object.defineProperty(Element.prototype, name, { ...descriptor, set(value) {
        const container = name === 'outerHTML' ? this.parentNode : this;
        Reflect.apply(descriptor.set, this, [value]);
        repairFrames(framesIn(container));
      } });
    } catch (_) { increment('repairFailures'); }
  }
  const adjacent = Element.prototype.insertAdjacentHTML;
  if (typeof adjacent === 'function') {
    try {
      Element.prototype.insertAdjacentHTML = new Proxy(adjacent, { apply(target, receiver, args) {
        const result = Reflect.apply(target, receiver, args);
        repairFrames(framesIn(receiver.parentNode || receiver));
        return result;
      } });
    } catch (_) { increment('repairFailures'); }
  }

  // Hide explicit advertising renderers; do not hide the video/player or error
  // messages. This layer does not disguise an unhandled playing video ad.
  function installCosmeticRules() {
    if (stats.cosmeticInstalled || !document.documentElement) return;
    const style = document.createElement('style');
    style.textContent = [
      'ytd-ad-slot-renderer', 'ytd-display-ad-renderer', 'ytd-in-feed-ad-layout-renderer',
      'ytd-promoted-sparkles-web-renderer', 'ytd-promoted-video-renderer',
      'ytd-companion-slot-renderer', 'ytm-promoted-sparkles-web-renderer',
      'ytm-promoted-video-renderer', '.ytp-ad-overlay-container', '.ytp-ad-image-overlay'
    ].join(',') + '{display:none!important}';
    document.documentElement.appendChild(style);
    stats.cosmeticInstalled = true;
  }
  installCosmeticRules();
  document.addEventListener('DOMContentLoaded', installCosmeticRules, { once: true });

  // A bounded fallback for an actual, already available skip button. No time
  // jumps, accelerated playback, muting, or forced playback of a paused video.
  let adWasShowing = false;
  let clicked = new WeakSet();
  let lastCheck = -Infinity;
  function skipAvailableAd() {
    if (document.hidden || performance.now() - lastCheck < 400) return;
    lastCheck = performance.now();
    const player = document.getElementById('movie_player');
    const adShowing = player?.classList.contains('ad-showing') === true;
    if (!adShowing) { adWasShowing = false; return; }
    if (!adWasShowing) { clicked = new WeakSet(); adWasShowing = true; }
    const video = player.querySelector('video');
    if (!video || video.paused || video.ended || video.error) return;
    const button = player.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
    if (!button || clicked.has(button) || button.disabled || button.getAttribute('aria-disabled') === 'true') return;
    const rect = button.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0 || getComputedStyle(button).visibility === 'hidden') return;
    clicked.add(button);
    button.click();
    increment('skipClicks');
  }
  document.addEventListener('timeupdate', skipAvailableAd, true);
  document.addEventListener('playing', skipAvailableAd, true);
  document.addEventListener('yt-navigate-finish', () => { adWasShowing = false; lastCheck = -Infinity; });
})();
