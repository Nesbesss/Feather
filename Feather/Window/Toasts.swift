import SwiftUI

/// Small messages at the bottom of the content: confirmations ("Password
/// saved") and questions with buttons ("Save password for github.com?").
@Observable
final class ToastCenter {
    struct Action: Identifiable {
        let id = UUID()
        var title: String
        var isPrimary = false
        var run: () -> Void
    }

    struct Toast: Identifiable {
        let id = UUID()
        var windowID: UUID?
        var symbol: String
        var message: String
        var actions: [Action] = []
        var compact = false
    }

    private(set) var toasts: [Toast] = []
    /// Where toasts shown without a window go: the browser window used last,
    /// so they are seen even while Feather isn't the active app.
    @ObservationIgnored var defaultWindowID: () -> UUID? = { nil }

    /// Shows a toast; plain messages go away by themselves, questions after a minute.
    @discardableResult
    func show(_ message: String, symbol: String = "checkmark.circle.fill", in windowID: UUID? = nil,
              actions: [Action] = [], duration: TimeInterval? = nil, compact: Bool = false) -> UUID {
        let toast = Toast(windowID: windowID ?? defaultWindowID(), symbol: symbol, message: message, actions: actions, compact: compact)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        let lifetime = duration ?? (actions.isEmpty ? 3 : 60)
        let id = toast.id
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in self?.dismiss(id) }
        return toast.id
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    func toasts(for windowID: UUID) -> [Toast] {
        toasts.filter { $0.windowID == windowID }
    }
}

struct ToastStack: View {
    let center: ToastCenter
    let windowID: UUID

    var body: some View {
        let glass = AppSettings.shared.glassInterface
        VStack(spacing: 8) {
            ForEach(center.toasts(for: windowID)) { toast in
                HStack(spacing: 10) {
                    Image(systemName: toast.symbol).foregroundStyle(.secondary)
                    Text(toast.message).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if !toast.actions.isEmpty {
                        Spacer(minLength: 8)
                        ForEach(toast.actions) { action in
                            Button(action.title) {
                                action.run()
                                center.dismiss(toast.id)
                            }
                            .toastButtonStyle(primary: action.isPrimary, glass: glass)
                            .controlSize(.small)
                        }
                    }
                    Button { center.dismiss(toast.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .fixedSize(horizontal: toast.compact, vertical: false)
                .frame(maxWidth: toast.compact ? nil : 560)
                .featherPanel(Capsule(), glass: glass)
                .shadow(color: .black.opacity(glass ? 0.08 : 0.15), radius: 8, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: center.toasts.map(\.id))
        .padding(.bottom, 4)
    }
}

private extension View {
    @ViewBuilder
    func toastButtonStyle(primary: Bool, glass: Bool) -> some View {
        if glass {
            if primary { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            buttonStyle(.borderedProminent).tint(primary ? .accentColor : .secondary.opacity(0.35))
        }
    }
}
