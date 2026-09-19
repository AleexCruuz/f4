// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import SwiftUI

/// The one colour in the panel that is not white, reserved for the model.
enum NotchAIStyle {
    static let colors = [Color(red: 0.76, green: 0.64, blue: 1.0), Color(red: 0.45, green: 0.8, blue: 1.0)]
    static var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A trailing action on a list row. Only these react to the pointer: the row
/// itself stays still, so moving across a list does not light up every entry
/// the pointer passes over on its way to a button.
struct NotchRowAction: View {
    enum Role { case plain, accent, destructive }

    let symbol: String
    let title: String
    var role = Role.plain
    /// Lit without the pointer: a pinned entry, an open menu.
    var active = false
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(NotchPressStyle(pressedScale: 0.88))
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: active)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: symbol)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var lit: Bool { enabled && (hovered || active) }

    private var foreground: AnyShapeStyle {
        switch role {
        case .destructive where lit: return AnyShapeStyle(Color(red: 1, green: 0.45, blue: 0.43))
        case .accent where lit: return AnyShapeStyle(NotchAIStyle.gradient)
        default: return AnyShapeStyle(.white.opacity(lit ? 1 : 0.5))
        }
    }

    private var background: AnyShapeStyle {
        guard lit else { return AnyShapeStyle(.white.opacity(0)) }
        switch role {
        case .destructive: return AnyShapeStyle(Color.red.opacity(0.17))
        case .accent: return AnyShapeStyle(NotchAIStyle.colors[0].opacity(0.16))
        case .plain: return AnyShapeStyle(.white.opacity(0.13))
        }
    }
}

/// Press feedback with no hover state, for a row whose click is a shortcut
/// rather than its visible affordance, and for the small controls above.
struct NotchPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The search row both lists lead with, with room for list-wide actions.
struct NotchListSearchField<Trailing: View>: View {
    let prompt: String
    @Binding var query: String
    @ViewBuilder var trailing: () -> Trailing
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $query).textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .accessibilityLabel(prompt)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(NotchPressStyle())
                .transition(.opacity)
            }
            trailing()
        }
        .frame(minHeight: 28)
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
        .modifier(NotchControlSurface(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(focused ? 0.34 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
    }
}

/// The AI actions, laid out inside the row that asked for them. A system
/// menu opens as a window of its own: outside the panel's look, and outside
/// the area the pointer has to stay in to keep the panel open.
struct NotchAIActionTray: View {
    let pick: (ClipboardAIAction) -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = FeatureStrings.clipboardAI(l10n.language)
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                ForEach(ClipboardAIAction.primary) { chip($0) }
            }
            Text(strings.toneMenu)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(ClipboardAIAction.tones) { chip($0) }
            }
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NotchAIStyle.gradient, lineWidth: 0.75)
                .opacity(0.35)
                .allowsHitTesting(false)
        }
    }

    private func chip(_ action: ClipboardAIAction) -> some View {
        NotchAIActionChip(symbol: action.symbolName, title: action.title(l10n.language)) { pick(action) }
    }
}

private struct NotchAIActionChip: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovered ? AnyShapeStyle(NotchAIStyle.gradient) : AnyShapeStyle(.white.opacity(0.55)))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(hovered ? 1 : 0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(.white.opacity(hovered ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(NotchPressStyle(pressedScale: 0.96))
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help(title)
    }
}

/// Light passing across whatever this masks, for as long as it is on screen.
/// Only the model's waits use it, so nothing runs while the panel is idle.
private struct NotchSweep<Mask: View>: View {
    var base: Color = .white.opacity(0.08)
    var highlight: [Color] = [.white.opacity(0), .white.opacity(0.24), .white.opacity(0)]
    var period = 1.6
    @ViewBuilder let mask: () -> Mask
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.5
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(base)
                    LinearGradient(colors: highlight, startPoint: .leading, endPoint: .trailing)
                        .frame(width: width * 0.5)
                        .offset(x: -width * 0.5 + width * 1.5 * phase)
                }
                .mask(alignment: .topLeading) { mask() }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The shape of an answer before its first word arrives.
struct NotchAIPlaceholder: View {
    private static let widths: [CGFloat] = [1, 0.94, 0.98, 0.58]

    var body: some View {
        NotchSweep {
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Self.widths.indices, id: \.self) { index in
                        Capsule().frame(width: proxy.size.width * Self.widths[index], height: 9)
                    }
                }
            }
        }
        .frame(height: CGFloat(Self.widths.count) * 18 - 9)
    }
}

/// A thin line under the heading that moves while the model works.
struct NotchAIProgressLine: View {
    var body: some View {
        NotchSweep(base: .white.opacity(0.06),
                   highlight: [NotchAIStyle.colors[0].opacity(0)] + NotchAIStyle.colors + [NotchAIStyle.colors[1].opacity(0)],
                   period: 1.3) {
            Capsule()
        }
        .frame(height: 2)
    }
}
