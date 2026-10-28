/* Feather's isolated-world YouTube catch notice. Native policy validation is
 * required before show(); this file never detects ads or controls playback.
 */
(() => {
  'use strict';
  const key = '__featherYouTubeAdNotice';
  if (globalThis.top !== globalThis || !/(^|\.)youtube(?:-nocookie)?\.com$/.test(location.hostname.toLowerCase().replace(/\.+$/, ''))
      || Object.hasOwn(globalThis, key)) return;

  const timing = { wait: 2200, deadline: 6000, settle: 250, acknowledge: 350, enter: 420, hold: 5000, exit: 220 };
  const curve = { enter: 'cubic-bezier(.23,1,.32,1)', exit: 'cubic-bezier(.55,0,1,.45)' };
  const selectors = [
    'ytd-masthead #masthead-logo a svg',
    'ytd-masthead ytd-topbar-logo-renderer #logo-icon',
    'ytd-masthead ytd-topbar-logo-renderer ytd-logo',
    'ytd-masthead a#logo',
    'ytm-home-logo button.mobile-topbar-header-endpoint .mobile-topbar-logo',
    'ytm-mobile-topbar-renderer .mobile-topbar-header-endpoint .mobile-topbar-logo',
    'ytm-mobile-topbar-renderer ytm-home-logo'
  ];
  let generation = 0, inactive = false, pending = null, current = null;
  // Native owns this optional feedback preference. Revisions reject an old
  // queued show after disable, including a quick off/on cycle.
  let enabled = false, preferenceRevision = -1;
  let navigatingUntil = 0, quietUntil = 0, lastHref = location.href;

  function settling() {
    if (lastHref !== location.href) { lastHref = location.href; quietUntil = Date.now() + timing.settle; }
    return Date.now() < Math.max(quietUntil, navigatingUntil);
  }

  function visibleBounds(node) {
    if (!node?.isConnected) return null;
    const rect = node.getBoundingClientRect();
    const style = getComputedStyle(node);
    if (rect.width < 8 || rect.height < 6 || style.display === 'none' || style.visibility !== 'visible'
        || Number(style.opacity) === 0 || rect.bottom <= 0 || rect.right <= 0
        || rect.top >= innerHeight || rect.left >= innerWidth) return null;
    // Opacity does not inherit: a child of a transparent shell still reports1.
    for (let parent = node.parentElement; parent; parent = parent.parentElement) {
      const parentStyle = getComputedStyle(parent);
      if (parentStyle.display === 'none' || parentStyle.visibility !== 'visible' || Number(parentStyle.opacity) === 0
          || parent.hasAttribute('hidden')) return null;
    }
    return rect;
  }

  function logo() {
    for (const selector of selectors) {
      for (const node of document.querySelectorAll(selector)) {
        const rect = visibleBounds(node);
        if (!rect || node.closest('.logo-in-player, ytd-guide-renderer, [hidden]')) continue;
        // Current shell and upgraded wordmarks both retain the red mark at
        // the left. Prefer its exact SVG path, then the 29:20 mark proportion.
        const paths = node.matches('svg') ? node.querySelectorAll('path') : node.querySelectorAll('svg path');
        for (const path of paths) {
          if (!/^(#ff0033|#ff0000|#f03|#f00|red)$/i.test(path.getAttribute('fill') || '')) continue;
          const mark = visibleBounds(path);
          if (mark && mark.width <= rect.width && mark.width / mark.height < 2) return { node: path, rect: mark };
        }
        return { node, rect: { left: rect.left, top: rect.top, width: Math.min(rect.width, rect.height * 1.45),
          height: rect.height, bottom: rect.bottom } };
      }
    }
    return null;
  }

  function clear() {
    generation++;
    pending?.cancel();
    pending = null;
    current?.dispose();
    current = null;
  }

  function setEnabled(value, revision) {
    if (typeof value !== 'boolean' || !Number.isSafeInteger(revision) || revision < 0 || revision < preferenceRevision) return false;
    if (revision === preferenceRevision && value !== enabled) return false;
    if (revision > preferenceRevision || !value) clear();
    preferenceRevision = revision;
    enabled = value;
    return enabled;
  }

  function mount(anchor, valid, alive, started, wall) {
    if (!valid() || !document.documentElement || document.fullscreenElement?.localName === 'video') return false;
    const host = document.createElement('div');
    host.id = 'feather-youtube-ad-notice';
    host.dataset.featherYoutubeNotice = '1';
    host.style.cssText = 'all:initial!important;position:fixed!important;display:block!important;width:max-content!important;max-width:calc(100vw - 16px)!important;z-index:2147483647!important;pointer-events:none!important;left:0;top:0;';
    const shadow = host.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    style.textContent = `
      :host { --notice-bg:rgba(255,255,255,.97); --notice-text:#202124; --notice-border:rgba(32,33,36,.13);
        --notice-shadow:0 8px 28px rgba(0,0,0,.16); --notice-accent:#ff0033; --notice-radius:24px;
        --notice-gap:10px; --notice-pad:12px; --notice-font:14px; --notice-height:44px; --notice-icon:26px; }
      :host([data-theme="dark"]) { --notice-bg:rgba(32,33,36,.97); --notice-text:#f8f8f8;
        --notice-border:rgba(255,255,255,.16); --notice-shadow:0 8px 28px rgba(0,0,0,.35); }
      [data-notice-card] { box-sizing:border-box; display:flex; align-items:center; gap:var(--notice-gap);
        width:max-content; max-width:calc(100vw - 16px); min-height:var(--notice-height); padding:8px var(--notice-pad);
        border:1px solid var(--notice-border); border-radius:var(--notice-radius); background:var(--notice-bg);
        color:var(--notice-text); box-shadow:var(--notice-shadow); -webkit-backdrop-filter:blur(16px); backdrop-filter:blur(16px);
        font:550 var(--notice-font)/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Arial,sans-serif;
        transform-origin:25px center; opacity:1; isolation:isolate; }
      svg { width:var(--notice-icon); height:19px; flex:none; color:var(--notice-accent); }
      [data-notice-message] { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      @media (prefers-reduced-transparency:reduce) { [data-notice-card] { -webkit-backdrop-filter:none; backdrop-filter:none; } }
    `;
    const card = document.createElement('div');
    card.dataset.noticeCard = '';
    card.setAttribute('role', 'status');
    card.setAttribute('aria-live', 'polite');
    card.setAttribute('aria-atomic', 'true');
    // Fixed local SVG and copy only. No response data, page text or URLs enter UI.
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 29 20');
    svg.setAttribute('aria-hidden', 'true');
    const body = document.createElementNS(svg.namespaceURI, 'path');
    body.setAttribute('fill', 'currentColor');
    body.setAttribute('d', 'M28.4 3.1A3.7 3.7 0 0 0 25.8.5C23.5 0 14.5 0 14.5 0S5.5 0 3.2.5A3.7 3.7 0 0 0 .6 3.1C0 5.4 0 10 0 10s0 4.6.6 6.9a3.7 3.7 0 0 0 2.6 2.6c2.3.5 11.3.5 11.3.5s9 0 11.3-.5a3.7 3.7 0 0 0 2.6-2.6c.6-2.3.6-6.9.6-6.9s0-4.6-.6-6.9Z');
    const play = document.createElementNS(svg.namespaceURI, 'path');
    play.setAttribute('fill', '#fff');
    play.setAttribute('d', 'm11.5 14.3 7.6-4.3-7.6-4.3Z');
    svg.append(body, play);
    const message = document.createElement('span');
    message.dataset.noticeMessage = '';
    message.textContent = 'Caught that ad for you!';
    card.append(svg, message);
    shadow.append(style, card);
    (document.fullscreenElement || document.documentElement).appendChild(host);

    const reduced = matchMedia('(prefers-reduced-motion: reduce)');
    host.dataset.reducedMotion = String(reduced.matches);
    let raf = 0, disposed = false, animations = [], repairs = 0, phase = 'waiting';
    let readableAt = Infinity, hideAt = Infinity, removeAt = Infinity, stableSince = 0, stableMark = '';
    let anchored = !!anchor, awaiting = [];
    const confirm = () => new Promise(resolve => awaiting.push(resolve));
    const resolve = value => { awaiting.splice(0).forEach(done => done(value)); };
    const ready = confirm();
    function position() {
      if (disposed) return null;
      host.dataset.theme = document.documentElement.hasAttribute('dark') ? 'dark' : 'light';
      const found = logo();
      // Layout dimensions stay stable while the card's transform unfolds.
      const bounds = { width: card.offsetWidth, height: card.offsetHeight };
      const viewport = globalThis.visualViewport;
      const minX = (viewport?.offsetLeft || 0) + 8, minY = (viewport?.offsetTop || 0) + 8;
      const maxX = minX + (viewport?.width || innerWidth) - 16 - bounds.width;
      const maxY = minY + (viewport?.height || innerHeight) - 16 - bounds.height;
      const rect = found?.rect;
      const x = Math.max(minX, Math.min(rect ? rect.left - 8 : minX + 8, Math.max(minX, maxX)));
      const y = Math.max(minY, Math.min(rect ? rect.bottom + 12 : minY + 8, Math.max(minY, maxY)));
      host.style.setProperty('left', `${x}px`, 'important');
      host.style.setProperty('top', `${y}px`, 'important');
      host.dataset.anchor = rect ? 'logo' : 'viewport';
      return { found, dx: rect ? rect.left + rect.width / 2 - (x + 25) : 0,
        dy: rect ? rect.top + rect.height / 2 - (y + bounds.height / 2) : -8 };
    }
    function dispose() {
      if (disposed) return;
      disposed = true;
      cancelAnimationFrame(raf);
      animations.forEach(animation => animation.cancel());
      reduced.removeEventListener?.('change', reduceMotion);
      host.remove();
      resolve(false);
      if (current?.host === host) current = null;
    }
    function reduceMotion() {
      host.dataset.reducedMotion = String(reduced.matches);
      if (reduced.matches) { animations.forEach(animation => animation.cancel()); animations = []; }
    }
    function pause() {
      if (disposed || phase === 'waiting') return;
      phase = 'waiting'; host.dataset.state = phase;
      host.style.setProperty('visibility', 'hidden', 'important');
      animations.forEach(animation => animation.cancel()); animations = [];
      stableSince = 0; stableMark = ''; readableAt = hideAt = removeAt = Infinity;
    }
    function enter(origin) {
      phase = 'entering'; host.dataset.state = phase;
      host.style.setProperty('visibility', 'visible', 'important');
      anchored = !!origin.found;
      const animate = !reduced.matches && typeof card.animate === 'function';
      readableAt = Date.now() + (animate ? timing.enter : 0);
      hideAt = readableAt + timing.hold;
      if (!animate) return;
      animations.push(card.animate([
        { opacity: 0, transform: `translate(${origin.dx}px,${origin.dy}px) scale(.82)`, clipPath: 'inset(0 calc(100% - 48px) 0 0 round 24px)' },
        { opacity: 1, transform: `translate(${origin.dx * .45}px,${origin.dy * .55}px) scale(.94)`, clipPath: 'inset(0 calc(100% - 48px) 0 0 round 24px)', offset: .22 },
        { opacity: 1, transform: 'translate(0,0) scale(1)', clipPath: 'inset(0 0 0 0 round 24px)' }
      ], { duration: timing.enter, easing: curve.enter }));
      animations.push(message.animate([{ opacity: 0, transform: 'translateX(-4px)' }, { opacity: 1, transform: 'translateX(0)' }],
        { duration: 220, delay: 120, easing: curve.enter, fill: 'backwards' }));
    }
    function exit(origin) {
      if (reduced.matches || typeof card.animate !== 'function') { dispose(); return; }
      phase = 'exiting'; host.dataset.state = phase; removeAt = Date.now() + timing.exit;
      animations.push(card.animate([
        { opacity: 1, transform: 'translate(0,0) scale(1)', clipPath: 'inset(0 0 0 0 round 24px)' },
        { opacity: 0, transform: `translate(${origin.dx}px,${origin.dy}px) scale(.82)`, clipPath: 'inset(0 calc(100% - 48px) 0 0 round 24px)' }
      ], { duration: timing.exit, easing: curve.exit, fill: 'forwards' }));
    }
    const origin = position();
    if (!valid() || !origin) { dispose(); return false; }
    current = { host, dispose, pause, confirm: () => {
      if (phase === 'visible' && Date.now() >= readableAt + timing.acknowledge) {
        hideAt = Date.now() + timing.hold;
        return Promise.resolve(true);
      }
      return confirm();
    } };
    enter(origin);
    reduced.addEventListener?.('change', reduceMotion);
    const follow = () => {
      if (disposed) return;
      const now = Date.now();
      if (!alive() || now - wall >= timing.deadline + timing.enter + timing.hold + timing.exit) { dispose(); return; }
      if (!host.isConnected) {
        if (repairs >= 2 || now - wall >= timing.deadline || !document.documentElement) { dispose(); return; }
        repairs++; pause();
        (document.fullscreenElement || document.documentElement).appendChild(host);
        host.dataset.repairs = String(repairs);
      }
      const changing = settling(), target = position();
      // A visible dwell must survive the page transition, not just DOM insertion.
      if (changing || (!anchored && target.found)) pause();
      if (phase === 'waiting') {
        if (!valid()) { dispose(); return; }
        const rect = target.found?.rect;
        const mark = rect ? [rect.left, rect.top, rect.width, rect.height].map(Math.round).join(',') : 'viewport';
        if (changing || mark !== stableMark) { stableMark = mark; stableSince = now; }
        if (!changing && now - stableSince >= timing.settle) enter(target);
      } else if (phase !== 'exiting') {
        if (now >= readableAt) { phase = 'visible'; host.dataset.state = phase; }
        if (now >= readableAt + timing.acknowledge) { host.dataset.presented = 'true'; resolve(true); }
        if (now >= hideAt) exit(target);
      } else if (now >= removeAt) { dispose(); return; }
      raf = requestAnimationFrame(follow);
    };
    raf = requestAnimationFrame(follow);
    return ready;
  }

  function show() {
    if (!enabled || inactive || document.hidden) return Promise.resolve(false);
    if (pending) return pending.promise;
    if (current) return current.confirm();
    const epoch = generation, started = performance.now(), wall = Date.now();
    const alive = () => enabled && !inactive && !document.hidden && epoch === generation;
    const valid = () => alive() && performance.now() - started < timing.deadline && Date.now() - wall < timing.deadline;
    let resolve, observer, timer, mounting = false, mark = '', stableSince = 0;
    const promise = new Promise(done => { resolve = done; });
    const finish = value => {
      if (pending?.promise !== promise) return;
      observer?.disconnect(); clearInterval(timer); pending = null; resolve(value);
    };
    pending = { promise, cancel: () => finish(false) };
    const attempt = () => {
      if (mounting) return;
      if (!valid()) { finish(false); return; }
      const changing = settling();
      const anchor = logo();
      const rect = anchor?.rect;
      const nextMark = rect ? [rect.left, rect.top, rect.width, rect.height].map(Math.round).join(',') : '';
      if (changing || mark !== nextMark) { mark = nextMark; stableSince = Date.now(); }
      if (changing || Date.now() - stableSince < timing.settle) return;
      if (!anchor && Date.now() - wall < timing.wait) return;
      mounting = true;
      Promise.resolve(mount(anchor, valid, alive, started, wall)).then(finish, () => finish(false));
    };
    observer = new MutationObserver(attempt);
    observer.observe(document.documentElement || document, { childList: true, subtree: true });
    timer = setInterval(attempt, 50);
    attempt();
    return promise;
  }

  Object.defineProperty(globalThis, key, { value: Object.freeze({ version: '2026.10.25.3', show, setEnabled }), configurable: false });
  addEventListener('pagehide', () => { inactive = true; clear(); });
  addEventListener('pageshow', () => { inactive = false; });
  document.addEventListener('visibilitychange', () => { if (document.hidden) clear(); });
  const navigateStart = () => { navigatingUntil = Date.now() + 1500; quietUntil = Date.now() + timing.settle; current?.pause(); };
  const navigateFinish = () => { navigatingUntil = 0; quietUntil = Date.now() + timing.settle; };
  document.addEventListener('yt-navigate-start', navigateStart);
  document.addEventListener('yt-navigate-finish', navigateFinish);
  addEventListener('state-navigatestart', navigateStart);
  addEventListener('state-navigateend', navigateFinish);
  document.addEventListener('fullscreenchange', clear);
})();
