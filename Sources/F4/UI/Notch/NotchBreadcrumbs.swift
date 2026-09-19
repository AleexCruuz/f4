// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import SwiftUI

/// The panel's whole navigation, written out. Every ancestor is a button, so
/// the trail is both the label for where you are and the way back — a plain
/// chevron next to it would be a second control for the same move.
struct NotchBreadcrumbs: View {
    let path: [NotchDestination]
    let navigate: (NotchDestination) -> Void
    @ObservedObject private var l10n = L10n.shared
    private var text: NotchStrings { FeatureStrings.notch(l10n.language) }

    var body: some View {
        Group {
            if path.isEmpty {
                // Nothing is installed, so there is no page to name.
                current(text.title)
            } else if path.count < 3 {
                trail(ancestors: Array(path.dropLast()), elided: false)
            } else {
                // Narrow panels drop the middle of the trail rather than the
                // parent: the link one level up is the one that gets used.
                ViewThatFits(in: .horizontal) {
                    trail(ancestors: Array(path.dropLast()), elided: false)
                    trail(ancestors: [path[path.count - 2]], elided: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("notch.breadcrumbs")
    }

    private func trail(ancestors: [NotchDestination], elided: Bool) -> some View {
        HStack(spacing: 1) {
            if elided {
                crumb(.sections, label: "…")
                separator
            }
            ForEach(ancestors) { destination in
                Group {
                    crumb(destination, label: title(destination))
                    separator
                }
            }
            current(path.last.map(title) ?? text.title)
        }
    }

    private func title(_ destination: NotchDestination) -> String {
        destination.title(l10n.language, l10n.s)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.28))
            .accessibilityHidden(true)
    }

    private func crumb(_ destination: NotchDestination, label: String) -> some View {
        Button { navigate(destination) } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 8, lifts: false))
        .accessibilityLabel(title(destination))
        .help(title(destination))
    }

    private func current(_ label: String) -> some View {
        Text(label)
            .font(.system(size: path.count > 2 ? 14 : 16, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, path.count > 1 ? 6 : 0)
            .accessibilityAddTraits(.isHeader)
    }
}

extension NotchDestination {
    func title(_ language: AppLanguage, _ s: Strings) -> String {
        switch self {
        case .sections: return FeatureStrings.notch(language).sectionsTitle
        case .module(let module): return module.title(language)
        case .settings: return s.panelSettings
        case .metric(let metric): return metric.title(s)
        case .clipboardAI(let action): return action.title(language)
        }
    }
}
