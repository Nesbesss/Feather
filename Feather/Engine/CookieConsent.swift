import Foundation
import WebKit
import os

/// Declines cookie pop-ups with DuckDuckGo's autoconsent, the engine their
/// WebKit browsers use (MPL-2.0, bundled unmodified in Resources/Consent).
///
/// Its content script runs in Feather's isolated world in every frame. It asks
/// Feather for its rules (`init`), and for the few consent platforms that need
/// the page's own JavaScript (`eval`, e.g. calling Didomi's opt-out API),
/// Feather runs that bundled snippet in the page's world and returns the result.
/// Feather also sends the Global Privacy Control signal.
final class CookieConsent: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = CookieConsent()
    static let messageName = "featherConsent"

    weak var state: BrowserState?
    private let log = Logger(subsystem: "dev.nesbes.Feather", category: "CookieConsent")
    private lazy var rules: ConsentRules? = {
        guard let url = Bundle.main.url(forResource: "compact-rules", withExtension: "json", subdirectory: "Consent"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? ConsentRules(json: data)
    }()

    /// Bridge plus the unmodified autoconsent bundle, in Feather's isolated world.
    private lazy var consentScript: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "autoconsent", withExtension: "js", subdirectory: "Consent"),
              let bundle = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let bridge = """
            window.autoconsentSendMessage = async (message) => {
              let reply;
              try { reply = await window.webkit.messageHandlers.\(Self.messageName).postMessage(message); } catch (e) { return; }
              if (reply && window.autoconsentReceiveMessage) window.autoconsentReceiveMessage(reply);
            };
            """
        return WKUserScript(source: bridge + "\n" + bundle, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                            in: .defaultClient)
    }()

    /// Global Privacy Control (`navigator.globalPrivacyControl`): a legally recognized
    /// "do not sell or share" signal that consent platforms such as OneTrust honor.
    private static let privacyControlScript = WKUserScript(source: """
        if (!('globalPrivacyControl' in Navigator.prototype)) {
          Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get() { return true; }, configurable: true, enumerable: true });
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    private static let config: [String: Any] = [
        "enabled": true, "autoAction": "optOut", "disabledCmps": [String](), "enablePrehide": true,
        "enableCosmeticRules": true, "enableGeneratedRules": true, "detectRetries": 20, "isMainWorld": false,
        "prehideTimeout": 2000, "enableHeuristicDetection": true, "enablePopupMutationObserver": false,
        "visualTest": false, "performanceLoggingEnabled": false, "heuristicPopupSearchTimeout": 1000, "heuristicMode": "tier1",
        "logs": ["lifecycle": false, "rulesteps": false, "detectionsteps": false, "evals": false, "errors": false,
                 "messages": false, "waits": false],
    ]

    func install(into controller: WKUserContentController, enabled: Bool) {
        guard enabled, let consentScript else { return }
        controller.addUserScript(Self.privacyControlScript)
        controller.addUserScript(consentScript)
        controller.addScriptMessageHandler(self, contentWorld: .defaultClient, name: Self.messageName)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return (nil, nil) }
        let frame = message.frameInfo
        switch type {
        case "init":
            let url = body["url"] as? String ?? frame.request.url?.absoluteString ?? ""
            guard let rules else { return (nil, nil) }
            return (["type": "initResp", "config": Self.config,
                     "rules": ["autoconsent": [Any](), "compact": rules.bundle(for: url, mainFrame: frame.isMainFrame)]], nil)
        case "eval":
            guard let id = body["id"] as? String, let code = body["code"] as? String, let webView = message.webView else {
                return (nil, nil)
            }
            let result = try? await webView.callAsyncJavaScript("return (\(code));", in: frame, contentWorld: .page)
            return (["type": "evalResp", "id": id, "result": Self.truthy(result)], nil)
        case "autoconsentDone":
            let cmp = body["cmp"] as? String ?? "cookie pop-up"
            log.info("Declined cookies via \(cmp, privacy: .public) on \(frame.securityOrigin.host, privacy: .public)")
            state?.tab(showing: message.webView)?.declinedCookies = cmp
            return (nil, nil)
        default:
            return (nil, nil)
        }
    }

    private static func truthy(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.doubleValue != 0
        case let string as String: return !string.isEmpty
        case nil, is NSNull: return false
        default: return true
        }
    }
}
