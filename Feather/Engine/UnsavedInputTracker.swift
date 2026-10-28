import WebKit

/// Latches editing protection for the current document, including embedded
/// login forms. Only a committed top-level navigation clears the native flag:
/// submitting a form can keep the same document alive in an SPA or login flow.
/// The isolated script sends no field values and performs no per-key DOM scans.
enum UnsavedInputTracker {
    static let messageName = "featherUnsavedInput"

    static let script = WKUserScript(source: """
        (() => {
          let reported = false;
          const protect = () => {
            if (reported) return;
            reported = true;
            webkit.messageHandlers.\(messageName).postMessage(true);
          };
          // Feather's password filler shares this isolated world. Latch there
          // too, so a back/forward-cache return can reassert filled-form state.
          globalThis.__featherProtectInput = protect;
          const editable = element => {
            if (!(element instanceof Element)) return false;
            if (element.isContentEditable) return true;
            if (element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) return true;
            return element instanceof HTMLInputElement
              && !['hidden', 'button', 'submit', 'reset', 'image'].includes(element.type);
          };
          const edited = event => {
            if (!reported && event.isTrusted && event.composedPath().some(editable)) protect();
          };
          addEventListener('input', edited, true);
          addEventListener('change', edited, true);

          // Some password managers fill without an input event. WebKit's autofill
          // pseudo-class reveals only that filling happened, never its contents.
          const autofilled = element => {
            if (!(element instanceof HTMLInputElement)) return false;
            try { return element.matches(':-webkit-autofill'); } catch { return false; }
          };
          const checkAutofill = () => {
            if (reported) return;
            try {
              if (document.querySelector('input:-webkit-autofill')) protect();
            } catch {}
          };
          addEventListener('focusin', event => {
            if (!reported && event.isTrusted && event.composedPath().some(autofilled)) protect();
          }, true);
          if (document.readyState === 'loading') {
            addEventListener('DOMContentLoaded', checkAutofill, { once: true });
          } else {
            checkAutofill();
          }
          addEventListener('pageshow', event => {
            // A back/forward cache restore reuses this script after native
            // navigation bookkeeping has reset the tab's document protection.
            if (event.isTrusted && event.persisted && reported) {
              webkit.messageHandlers.\(messageName).postMessage(true);
            } else {
              checkAutofill();
            }
          });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
}
