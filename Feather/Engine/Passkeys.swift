import AuthenticationServices
import Security
import WebKit

/// Passkeys and security keys on the web. WebKit handles WebAuthn itself
/// (your Mac's passkeys, a phone over Bluetooth, USB keys), but only for apps
/// Apple has granted the browser entitlement. Until Feather has it, pages are
/// told WebAuthn isn't available, so sites offer password sign-in instead of
/// a passkey prompt that can only fail.
enum Passkeys {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    enum Status {
        case needsEntitlement, notDetermined, allowed, denied
    }

    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool) == true
    }()

    static var status: Status {
        guard isEntitled else { return .needsEntitlement }
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .authorized: return .allowed
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    /// Asks once for permission to use the user's passkeys (System Settings lists the grant).
    static func requestAuthorizationIfNeeded() {
        guard isEntitled, status == .notDetermined else { return }
        ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in }
    }

    static func install(into controller: WKUserContentController) {
        if !isEntitled { controller.addUserScript(fallbackScript) }
    }

    /// Runs in the page's own world so the site's feature detection sees it.
    private static let fallbackScript = WKUserScript(source: """
        (() => {
          try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true, writable: true }); } catch (e) {}
          const credentials = navigator.credentials;
          if (!credentials) return;
          const unavailable = () => Promise.reject(new DOMException('Passkeys are not available in this browser.', 'NotAllowedError'));
          for (const name of ['get', 'create']) {
            const original = typeof credentials[name] === 'function' ? credentials[name].bind(credentials) : null;
            if (!original) continue;
            try {
              Object.defineProperty(credentials, name, { configurable: true, writable: true,
                value: options => (options && options.publicKey) ? unavailable() : original(options) });
            } catch (e) {}
          }
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
}
