import WebKit

/// Reports the link under the pointer so Feather can show its URL, like
/// Safari's status bar. Isolated content world; main frame only.
enum LinkHoverScript {
    static let messageName = "featherLinkHover"

    static let script = WKUserScript(source: """
        (() => {
          let current = null;
          const report = href => {
            if (href === current) return;
            current = href;
            try { webkit.messageHandlers.\(messageName).postMessage(href); } catch (e) {}
          };
          addEventListener('mouseover', event => {
            const link = event.target.closest && event.target.closest('a[href]');
            report(link ? link.href : null);
          }, true);
          addEventListener('mouseout', event => { if (!event.relatedTarget) report(null); }, true);
          addEventListener('pagehide', () => report(null), true);
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
}
