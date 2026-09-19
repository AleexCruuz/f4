// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import SwiftUI

/// A row's title with its explanation beneath it. The explanation belongs to
/// the control's label, so control and explanation read as one row instead
/// of two rows split by a separator.
struct SettingsLabel: View {
    let title: String
    let caption: String?

    init(_ title: String, caption: String? = nil) {
        self.title = title
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if let caption, !caption.isEmpty {
                SettingsCaptionText(caption)
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Secondary text for a row or a section footer.
struct SettingsCaptionText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineSpacing(1.5)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // Grouped forms right-align section footers; explanations read
            // from the leading edge like the rows above them.
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsToggleWithCaption: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(title, caption: caption)
        }
    }
}

/// Switch for a section whose header already names the feature: the row
/// shows only what turning it on does instead of repeating the name, and
/// VoiceOver still reads the name.
struct SettingsDescribedToggle: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(caption)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(title)
        .accessibilityHint(caption)
    }
}

/// Options a group needs only now and then, folded until asked for.
struct SettingsMoreOptions<Content: View>: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var isExpanded = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Text(FeatureStrings.settingsLayout(l10n.language).moreOptions)
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// Hides a control that has nothing to do right now while keeping its
    /// place, so a column of rows stays aligned instead of showing a stack
    /// of greyed-out buttons.
    func showsOnlyWhen(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    /// Room every Settings page shares, applied once around the page so no
    /// page carries its own spacing.
    func settingsPageSpacing() -> some View {
        environment(\.defaultMinListRowHeight, 40)
            .contentMargins(.horizontal, 14, for: .scrollContent)
            .contentMargins(.vertical, 12, for: .scrollContent)
    }
}
