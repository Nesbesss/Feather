import WebKit

/// Finds login fields, reports focus and submitted credentials to Feather, and
/// fills saved logins. Runs in every frame, in Feather's own content world:
/// pages can't see these functions or post to Feather's handler. Feather takes
/// each message's origin from WebKit (`frameInfo.securityOrigin`), never from
/// the page.
enum LoginFormScript {
    static let messageName = "featherPasswords"

    static let script = WKUserScript(source: """
        (() => {
          const post = message => { try { webkit.messageHandlers.\(messageName).postMessage(message); } catch (e) {} };
          const shown = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'; };
          const isPassword = el => el instanceof HTMLInputElement && el.type === 'password';
          const isText = el => el instanceof HTMLInputElement && ['text', 'email', 'tel', ''].includes(el.type);
          const passwordsIn = scope => [...(scope || document).querySelectorAll('input[type=password]')].filter(shown);
          const scopeOf = el => (el && el.form) || document;

          const usernameFor = password => {
            const inputs = [...scopeOf(password).querySelectorAll('input')].filter(shown);
            const declared = inputs.find(i => i !== password && /username|email/.test(i.autocomplete || ''));
            if (declared) return declared;
            for (let i = inputs.indexOf(password) - 1; i >= 0; i--) if (isText(inputs[i])) return inputs[i];
            return null;
          };

          // Username fields count even before a password field appears (Google-style multi-step sign-in).
          const fieldKind = el => {
            if (isPassword(el)) {
              const isNew = el.autocomplete === 'new-password' || passwordsIn(scopeOf(el)).length >= 2;
              return { kind: 'password', isNew };
            }
            if (isText(el)) {
              const hints = (el.autocomplete || '') + ' ' + (el.name || '') + ' ' + (el.id || '');
              if (passwordsIn(scopeOf(el)).length || /username|email|user|login/i.test(hints)) return { kind: 'username', isNew: false };
            }
            return null;
          };

          // Input handling only needs Boolean membership. Preserve full focus
          // classification, and never cache a result across DOM/input events.
          const isLoginInput = el => {
            if (isPassword(el)) return true;
            if (!isText(el)) return false;
            const hints = (el.autocomplete || '') + ' ' + (el.name || '') + ' ' + (el.id || '');
            if (/username|email|user|login/i.test(hints)) return true;
            for (const password of scopeOf(el).querySelectorAll('input[type=password]')) {
              if (shown(password)) return true;
            }
            return false;
          };

          let focused = null;
          let typedUsername = '';
          let lastReported = '';

          addEventListener('focusin', event => {
            const info = fieldKind(event.target);
            if (!info) return;
            focused = event.target;
            const r = focused.getBoundingClientRect();
            post({ type: 'focus', kind: info.kind, isNew: info.isNew, rect: [r.left, r.top, r.width, r.height], isTopFrame: window === top });
          }, true);

          addEventListener('input', event => {
            if (!event.isTrusted || !isLoginInput(event.target)) return;
            if (isText(event.target)) typedUsername = event.target.value;
            post({ type: 'typing' });
          }, true);

          const capture = (near, knownScope = null, knownPasswords = null) => {
            const scope = scopeOf(near);
            const passwords = knownScope === scope && knownPasswords !== null ? knownPasswords : passwordsIn(scope);
            const filled = passwords.filter(p => p.value);
            if (!filled.length) return;
            const password = filled[filled.length - 1];  // on change-password forms the last field is the new one
            const user = usernameFor(password);
            const username = (user && user.value) || typedUsername || '';
            const key = username + '\\u0000' + password.value;
            if (key === lastReported) return;
            lastReported = key;
            post({ type: 'credentials', username, password: password.value });
          };
          addEventListener('submit', event => capture(event.target.querySelector('input[type=password]')), true);
          addEventListener('keydown', event => { if (event.key === 'Enter' && isPassword(event.target)) capture(event.target); }, true);
          addEventListener('click', event => {
            const button = event.target.closest && event.target.closest('button, input[type=submit], [role=button]');
            if (button) {
              const scope = scopeOf(button);
              const passwords = passwordsIn(scope);
              capture(passwords[0] || null, scope, passwords);
            }
          }, true);
          addEventListener('pagehide', () => capture(null), true);

          const setValue = (el, value) => {
            if (!el || value === null || value === undefined) return;
            el.focus();
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };

          // Called by Feather in this content world. A null password fills only the username.
          window.__featherFill = (username, password) => {
            const target = focused && document.contains(focused) ? focused : (passwordsIn()[0] || null);
            const passwordField = target && isPassword(target) ? target : passwordsIn(scopeOf(target))[0] || null;
            const usernameField = target && isText(target) ? target : (passwordField ? usernameFor(passwordField) : null);
            setValue(usernameField, username);
            if (password !== null) setValue(passwordField, password);
            if (password !== null) lastReported = username + '\\u0000' + password;  // don't offer to save what was just filled
            typedUsername = username;
            return !!(usernameField || passwordField);
          };

          window.__featherFillNewPassword = password => {
            const fields = passwordsIn(scopeOf(focused)).filter(p => p.autocomplete !== 'current-password');
            fields.forEach(field => setValue(field, password));
            return fields.length > 0;
          };
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)
}
