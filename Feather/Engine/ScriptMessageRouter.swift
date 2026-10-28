import WebKit

/// One handler object for all of Feather's page-script messages, registered in
/// Feather's isolated content world on every web view's controller and
/// dispatching by message name.
final class ScriptMessageRouter: NSObject, WKScriptMessageHandler {
    static let names = [UnsavedInputTracker.messageName, LoginFormScript.messageName, LinkHoverScript.messageName,
                        MediaScript.messageName, ReaderMode.messageName, PageLayoutScript.messageName]

    var handlers: [String: (WKScriptMessage) -> Void] = [:]

    func install(into controller: WKUserContentController) {
        for name in Self.names { controller.add(self, contentWorld: .defaultClient, name: name) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handlers[message.name]?(message)
    }
}
