import WebKit

/// Looks at how a page is laid out, for the smart sidebar: does the site have
/// its own navigation panel along the left edge (Gmail's folders, YouTube's
/// guide, ChatGPT's chats), and does it work like an app (the page itself
/// doesn't scroll)? Isolated content world, main frame only. It only reads
/// layout, a few times per page: after load, on resize, and when a single-page
/// app changes its URL. It also passes on the page's meta description, which
/// tab groups use to tell what a page is about.
enum PageLayoutScript {
    static let messageName = "featherLayout"

    static let script = WKUserScript(source: """
        (() => {
          if (window.__featherLayout) return;
          window.__featherLayout = true;
          const controls = 'a[href], button, [role="button"], [role="link"], [role="treeitem"], [role="tab"], [role="menuitem"]';
          const post = (message) => { try { webkit.messageHandlers.\(messageName).postMessage(message); } catch (e) {} };

          // The narrow, tall, control-filled box under a point near the left edge, if any.
          const panelAt = (x, y, vw, vh) => {
            let el = document.elementFromPoint(x, y);
            for (let depth = 0; el && el !== document.body && el !== document.documentElement && depth < 30; depth++, el = el.parentElement) {
              const r = el.getBoundingClientRect();
              if (r.width > Math.min(440, vw * 0.42)) return null;  // wider than a sidebar: this is the page
              if (r.left > 12 || r.width < 48 || r.height < vh * 0.6) continue;
              if (el.querySelectorAll(controls).length < 4) continue;
              return el;
            }
            return null;
          };

          let last = '';
          const probe = () => {
            const vw = innerWidth, vh = innerHeight;
            if (vw < 320 || vh < 240 || document.visibilityState !== 'visible') return;
            let panel = null;
            for (const fy of [0.4, 0.6, 0.8]) {
              for (const x of [14, 36]) { panel = panelAt(x, vh * fy, vw, vh); if (panel) break; }
              if (panel) break;
            }
            const labels = [];
            if (panel) {
              const seen = new Set();
              for (const el of panel.querySelectorAll(controls)) {
                const text = (el.getAttribute('aria-label') || el.textContent || '').trim().replace(/\\s+/g, ' ');
                if (text.length <= 1 || text.length >= 40 || seen.has(text)) continue;
                seen.add(text);
                labels.push(text);
                if (labels.length === 10) break;
              }
            }
            const scroller = document.scrollingElement || document.documentElement;
            const app = scroller.scrollHeight <= vh + 4 && document.querySelectorAll(controls).length > 40;
            const meta = document.querySelector('meta[name="description"], meta[property="og:description"]');
            const summary = ((meta && meta.content) || '').trim().replace(/\\s+/g, ' ').slice(0, 200);
            const message = { sidebar: panel ? Math.round(panel.getBoundingClientRect().width) : null, labels, app, summary };
            const key = JSON.stringify(message);
            if (key === last) return;
            last = key;
            post(message);
          };

          let timer = null;
          const soon = (delay) => { clearTimeout(timer); timer = setTimeout(probe, delay); };
          const start = () => soon(900);
          if (document.readyState === 'complete') start(); else addEventListener('load', start, { once: true });
          addEventListener('resize', () => soon(400));
          // Single-page apps change the URL without loading a new document.
          // Only the visible page needs sidebar layout updates; retained hidden
          // tabs must not each wake JavaScript just to poll their address.
          let href = location.href;
          let locationTimer = null;
          const checkLocation = () => {
            if (location.href !== href) { href = location.href; soon(700); }
          };
          const visibilityChanged = () => {
            clearInterval(locationTimer);
            locationTimer = null;
            clearTimeout(timer);
            if (document.visibilityState !== 'visible') return;
            checkLocation();
            soon(300);
            locationTimer = setInterval(checkLocation, 1500);
          };
          document.addEventListener('visibilitychange', visibilityChanged);
          addEventListener('pageshow', visibilityChanged);
          visibilityChanged();
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
}
