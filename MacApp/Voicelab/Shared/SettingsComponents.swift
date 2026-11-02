import SwiftUI

/// A titled block: a short heading and one-line description above its grouped rows.
struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text(title))
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(AppLocalization.text(subtitle))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4).padding(.bottom, 12)
            content
            if let footer {
                Text(AppLocalization.text(footer))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 10)
            }
        }
    }
}

let settingsGroupRadius: CGFloat = 12

/// A one-pixel, low-contrast column separator. `Divider` renders heavy and dark here,
/// so columns use this instead.
struct ColumnHairline: View {
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

/// A rounded, softly filled group of rows separated by inset dividers.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: settingsGroupRadius, style: .continuous))
    }
}

/// Title and optional description on the leading edge, the control on the trailing edge.
struct SettingsRow<Control: View>: View {
    let title: String
    /// A localization key for the description.
    var detail: String?
    /// A description shown as-is, such as sample text or a server message.
    var verbatimDetail: String?
    /// Shows the description as a problem to fix, such as a rejected shortcut.
    var detailIsError = false
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    init(_ title: String, verbatimDetail: String?, detailIsError: Bool = false,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.verbatimDetail = verbatimDetail
        self.detailIsError = detailIsError
        self.control = control()
    }

    private var description: String? { detail.map { AppLocalization.text($0) } ?? verbatimDetail }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text(title)).font(.system(size: 13))
                if let description {
                    Text(description).font(.system(size: 12))
                        .foregroundStyle(detailIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.font(.system(size: 13)).fixedSize()
        }
        .padding(.vertical, 12)
        .frame(minHeight: 44)
    }
}

extension View {
    /// Compact pop-up menu matching the trailing controls in macOS settings.
    func settingsMenu() -> some View {
        labelsHidden().pickerStyle(.menu).fixedSize()
    }
}

/// A settings choice shown as just its current value and ⌃⌄, hugging the row's right edge
/// (a pop-up button is as wide as its longest option and left-aligns the value).
struct SettingsMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            Picker(AppLocalization.text(title), selection: $selection) {
                ForEach(options, id: \.self) { Text(verbatim: label($0)).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: label(selection))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(isEnabled ? Design.tint : Color.secondary)
        .tint(Design.tint)
        .accessibilityLabel(AppLocalization.text(title))
        .accessibilityValue(label(selection))
    }
}
