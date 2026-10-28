import SwiftUI

/// A quiet, local start surface. It never creates a web view or a network request.
struct StartPageView: View {
    var glass = false
    @State private var hoveringSearch = false

    private enum Layout {
        static let width: CGFloat = 310
        static let inset: CGFloat = 18
        static let mark: CGFloat = 72
        static let corner: CGFloat = 14
    }

    var body: some View {
        VStack(spacing: 0) {
            Image("FeatherMark")
                .resizable()
                .scaledToFit()
                .frame(width: Layout.mark, height: Layout.mark)
                .accessibilityHidden(true)

            Text("Feather")
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .tracking(-0.8)
                .padding(.top, 12)

            Text("A little room to explore.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Button {
                NSApp.sendAction(#selector(BrowserWindowController.openLocation(_:)), to: nil, from: nil)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    Text("Search or enter address")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("⌘L")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 15)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: Layout.corner))
            }
            .buttonStyle(.plain)
            .featherSurface(RoundedRectangle(cornerRadius: Layout.corner, style: .continuous),
                            glass: glass, fill: hoveringSearch ? 0.075 : 0.045, interactive: true)
            .onHover { hoveringSearch = $0 }
            .help("Search or enter an address (⌘L)")
            .accessibilityLabel("Search or enter an address")
            .accessibilityHint("Opens the address field. Type a website or a search, then press Return.")
            .accessibilityIdentifier("feather.start.search")
            .padding(.top, 24)

            HStack(spacing: 12) {
                shortcut("New tab", keys: "⌘T", action: #selector(BrowserWindowController.newTab(_:)),
                         identifier: "feather.start.new-tab")
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showWelcomeGuide(_:)), to: nil, from: nil)
                } label: {
                    Label("Quick tour", systemImage: "questionmark.circle")
                        .font(.system(size: 11))
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Replay the welcome guide")
                .accessibilityLabel("Replay the welcome guide")
                .accessibilityIdentifier("feather.start.quick-tour")
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: Layout.width)
        .padding(Layout.inset)
    }

    private func shortcut(_ title: String, keys: String, action: Selector, identifier: String) -> some View {
        Button {
            NSApp.sendAction(action, to: nil, from: nil)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text(keys)
                    .font(.system(size: 10, design: .monospaced))
            }
            .font(.system(size: 11))
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Open a new tab (\(keys))")
        .accessibilityLabel(title)
        .accessibilityHint("Keyboard shortcut: \(keys)")
        .accessibilityIdentifier(identifier)
    }
}
