import WebKit

/// Reader view (⇧⌘R) with Mozilla's Readability, the article extractor Firefox
/// uses (Apache-2.0, bundled unmodified in Resources/Reader).
///
/// Every page gets only the 4 KB `isProbablyReaderable` check, which lights up
/// the reader button. The 90 KB parser is loaded only when you open reader
/// view. The article is drawn over the page in a closed shadow root in
/// Feather's isolated world, so there is no extra web process and the page's
/// own scripts can't reach it.
enum ReaderMode {
    static let messageName = "featherReader"

    private static func resource(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Reader")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// Main frame only; reports once the page has settled.
    static let readerableScript = WKUserScript(source: resource("Readability-readerable") + """

        (() => {
          const check = () => {
            let readerable = false;
            try { readerable = isProbablyReaderable(document); } catch (e) {}
            try { webkit.messageHandlers.\(messageName).postMessage({ readerable }); } catch (e) {}
          };
          const later = () => setTimeout(() => (window.requestIdleCallback || setTimeout)(check), 600);
          if (document.readyState === 'complete') later(); else addEventListener('load', later, { once: true });
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

    private static let parser = resource("Readability")

    /// Opens or closes reader view. Returns whether it is now open.
    @discardableResult
    static func toggle(in webView: WKWebView, fontSize: Double) async -> Bool {
        let hasParser = (try? await webView.callAsyncJavaScript("return typeof Readability === 'function';",
                                                                 in: nil, contentWorld: .defaultClient)) as? Bool ?? false
        if !hasParser { _ = try? await webView.evaluateJavaScript(parser, in: nil, contentWorld: .defaultClient) }
        let result = try? await webView.callAsyncJavaScript(overlay, arguments: ["fontSize": fontSize],
                                                             in: nil, contentWorld: .defaultClient)
        return result as? Bool ?? false
    }

    /// The article's title, plain text, and language, for reading aloud.
    static func article(in webView: WKWebView) async -> (title: String, text: String, language: String?)? {
        let hasParser = (try? await webView.callAsyncJavaScript("return typeof Readability === 'function';",
                                                                 in: nil, contentWorld: .defaultClient)) as? Bool ?? false
        if !hasParser { _ = try? await webView.evaluateJavaScript(parser, in: nil, contentWorld: .defaultClient) }
        let result = try? await webView.callAsyncJavaScript("""
            let article = null;
            try { article = new Readability(document.cloneNode(true)).parse(); } catch (e) {}
            if (!article || !article.textContent) return null;
            return { title: article.title || document.title, text: article.textContent, lang: article.lang || document.documentElement.lang || null };
            """, in: nil, contentWorld: .defaultClient) as? [String: Any]
        guard let result, let text = result["text"] as? String, !text.isEmpty else { return nil }
        return (result["title"] as? String ?? "", text, result["lang"] as? String)
    }

    private static let overlay = """
        const existing = document.getElementById('__feather_reader');
        if (existing) { existing.__close(); return false; }
        let article = null;
        try { article = new Readability(document.cloneNode(true)).parse(); } catch (e) {}
        if (!article || !article.content) return false;

        const esc = (s) => String(s || '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
        const minutes = Math.max(1, Math.round((article.length || 0) / 1150));
        const site = article.siteName || location.hostname.replace(/^www\\./, '');
        const host = document.createElement('div');
        host.id = '__feather_reader';
        host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;';
        const root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = `
          <style>
            :host { all: initial; }
            .page { position: absolute; inset: 0; overflow: auto; background: #fbfaf7; color: #1d1d1f;
                    font: var(--size) / 1.65 ui-serif, "New York", Georgia, serif; -webkit-font-smoothing: antialiased; }
            .page.sans { font-family: -apple-system, "SF Pro Text", sans-serif; }
            @media (prefers-color-scheme: dark) { .page { background: #1c1c1e; color: #e6e6e8; } a { color: #6cb4ff; } }
            .bar { position: sticky; top: 0; display: flex; gap: 6px; justify-content: flex-end; padding: 10px 14px;
                   font: 13px -apple-system, sans-serif; background: inherit; opacity: .55; transition: opacity .2s; }
            .bar:hover { opacity: 1; }
            button { font: inherit; color: inherit; background: rgba(127,127,127,.15); border: 0; border-radius: 6px;
                     padding: 4px 10px; cursor: pointer; }
            main { max-width: 680px; margin: 0 auto; padding: 8px 28px 120px; }
            .site { font: 600 13px -apple-system, sans-serif; text-transform: uppercase; letter-spacing: .06em; opacity: .6; margin: 0; }
            h1 { font-size: 1.9em; line-height: 1.2; margin: .3em 0 .3em; }
            .byline { font: 14px -apple-system, sans-serif; opacity: .65; margin: 0 0 2.2em; }
            article img, article video, article svg { max-width: 100%; height: auto; border-radius: 6px; }
            article figure { margin: 1.6em 0; } article figcaption { font: 13px -apple-system, sans-serif; opacity: .65; }
            article pre { overflow: auto; font-size: .8em; background: rgba(127,127,127,.12); padding: 12px; border-radius: 8px; }
            article blockquote { margin: 1.4em 0; padding-left: 1em; border-left: 3px solid rgba(127,127,127,.4); opacity: .85; }
            article table { border-collapse: collapse; font-size: .85em; } article td, article th { padding: 4px 8px; border: 1px solid rgba(127,127,127,.3); }
            a { color: #0a64d8; }
          </style>
          <div class="page" style="--size: ${fontSize}px">
            <div class="bar">
              <button data-act="smaller" title="Smaller text">A−</button>
              <button data-act="bigger" title="Larger text">A+</button>
              <button data-act="font" title="Serif or sans-serif">Aa</button>
              <button data-act="close" title="Close reader (Esc)">Done</button>
            </div>
            <main>
              <p class="site">${esc(site)}</p>
              <h1>${esc(article.title)}</h1>
              <p class="byline">${article.byline ? esc(article.byline) + ' · ' : ''}${minutes} min read</p>
              <article>${article.content}</article>
            </main>
          </div>`;
        const page = root.querySelector('.page');
        const post = (message) => { try { webkit.messageHandlers.\(messageName).postMessage(message); } catch (e) {} };
        const overflow = document.documentElement.style.overflow;
        const onKey = (event) => { if (event.key === 'Escape') { event.preventDefault(); host.__close(); } };
        // The page underneath can't be clicked, focused, or read out while reader view is up.
        const body = document.body, wasInert = body ? body.inert : false;
        host.__close = () => {
          host.remove();
          if (body) body.inert = wasInert;
          document.documentElement.style.overflow = overflow;
          removeEventListener('keydown', onKey, true);
          post({ open: false });
        };
        let size = fontSize;
        root.querySelector('.bar').addEventListener('click', (event) => {
          const act = event.target.closest('button')?.dataset.act;
          if (act === 'close') return host.__close();
          if (act === 'font') return page.classList.toggle('sans');
          if (act === 'smaller' || act === 'bigger') {
            size = Math.min(30, Math.max(14, size + (act === 'bigger' ? 1 : -1)));
            page.style.setProperty('--size', size + 'px');
            post({ fontSize: size });
          }
        });
        addEventListener('keydown', onKey, true);
        document.documentElement.style.overflow = 'hidden';
        if (body) body.inert = true;
        document.documentElement.appendChild(host);
        page.tabIndex = -1;
        page.focus();
        return true;
        """
}
