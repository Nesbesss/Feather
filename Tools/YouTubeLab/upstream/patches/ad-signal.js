// FEATHER-AG251-ADSIGNAL-001: evidence at successful ad-only mutation boundaries.
// The embedding coordinator may supply this lexical callback; no page bridge,
// global debug hook, response contents, URL, video ID or rule text is exposed.
const featherAdEvidence = (() => {
  const callback = typeof __FEATHER_AD_INTERVENTION__ === 'function'
    ? __FEATHER_AD_INTERVENTION__ : null;
  let emitted = 0;
  let pending = null;
  const own = (value, key) => {
    try { return value !== null && typeof value === 'object'
      ? Object.getOwnPropertyDescriptor(value, key)?.value : undefined; }
    catch (_) { return undefined; }
  };
  const nonempty = value => value !== null && typeof value === 'object'
    && (Array.isArray(value) ? value.length > 0 : Object.keys(value).length > 0);
  const deliver = kind => {
    if (!callback || emitted >= 1000000) return;
    emitted++;
    try { callback(kind); } catch (_) { /* Notification cannot affect playback. */ }
  };
  return {
    previous: own,
    length(value) { try { return value.length; } catch (_) { return undefined; } },
    deleted(source, base, property, previous) {
      try { if (!Object.hasOwn(base, property)) this.mutation(source, property, previous); } catch (_) {}
    },
    spliced(source, base, property, previous, length) {
      try { if (base.length === length - 1) this.mutation(source, property, previous); } catch (_) {}
    },
    mutation(source, property, previous) {
      if (!callback) return;
      try {
        const path = source.args?.[0] || '';
        const metadata = ['adPlacements', 'adSlots', 'playerAds', 'adSlotRenderer'].includes(property)
          && nonempty(previous);
        const short = path.includes('.isAd')
          && own(own(own(previous, 'command'), 'reelWatchEndpoint'), 'adClientParams')
          && own(own(own(own(previous, 'command'), 'reelWatchEndpoint'), 'adClientParams'), 'isAd') === true;
        const feed = path.includes('adSlotRenderer') && (
          nonempty(own(previous, 'adSlotRenderer'))
          || nonempty(own(own(own(previous, 'richItemRenderer'), 'content'), 'adSlotRenderer')));
        if (!metadata && !short && !feed) return;
        const kind = source.name === 'set-constant' ? 'ad-data-suppressed' : 'ad-data-removed';
        if (pending) pending.add(kind); else deliver(kind);
      } catch (_) { /* Do not evaluate getters or fail the original operation. */ }
    },
    capture(run) {
      const parent = pending, captured = new Set();
      pending = captured;
      try {
        const value = run();
        return { value, commit() {
          for (const kind of captured) { if (parent) parent.add(kind); else deliver(kind); }
          captured.clear();
        }};
      } finally { pending = parent; }
    }
  };
})();
