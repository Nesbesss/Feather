import AppKit
import SwiftUI

/// Shared spacing and surfaces keep every settings page part of the same window.
enum SettingsTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.40, green: 0.75, blue: 0.65, alpha: 1)
            : NSColor(srgbRed: 0.20, green: 0.51, blue: 0.45, alpha: 1)
    })
    static let secondaryText = Color.secondary
    static let border = Color(nsColor: .separatorColor).opacity(0.45)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 26, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 2)
                content()
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SettingsTheme.pageBackground)
        .tint(SettingsTheme.accent)
        .accessibilityIdentifier("feather.settings.page.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

struct SettingsSectionHeader: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 2)
    }
}

struct SettingsCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { SettingsSectionHeader(title) }
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SettingsTheme.border, lineWidth: 0.5))
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: () -> Control

    init(title: String, subtitle: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().controlSize(.regular).layoutPriority(1)
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct SettingsNote: View {
    let text: String
    var systemImage: String

    init(_ text: String, systemImage: String = "info.circle") {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        } icon: {
            Image(systemName: systemImage).font(.system(size: 12))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 2)
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(SettingsTheme.border).frame(height: 0.5).padding(.leading, 16) }
}

struct SettingsToggle: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var identifier: String? = nil

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier(identifier ?? "feather.settings.toggle.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
    }
}
