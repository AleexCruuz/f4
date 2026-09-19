// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import SwiftUI

/// What the model is doing, and what it produced, on one page.
///
/// The original sits above the answer rather than behind a toggle: the whole
/// judgement the user has to make is whether the result still says what the
/// text said, and that is not a judgement anyone makes from memory.
struct NotchClipboardAIView: View {
    let run: ClipboardAIService.Run
    @ObservedObject private var ai = ClipboardAIService.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var confirmation: Confirmation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var strings: ClipboardAIStrings { FeatureStrings.clipboardAI(l10n.language) }

    private enum Confirmation { case copied, replaced }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            source
            result
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: confirmation == nil) {
            guard confirmation != nil else { return }
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            confirmation = nil
        }
    }

    // MARK: - Panes

    private var source: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(strings.sourceHeading, symbol: "text.quote")
            // A quarter of the page at most: it is context, and the answer is
            // the thing being read. Short text takes only its own height.
            CappedHeight(maximum: 64) {
                ScrollView { sourceText }.scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, 4)
    }

    private var sourceText: some View {
        Text(run.source)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label {
                    Text(strings.resultHeading)
                } icon: {
                    Image(systemName: run.action.symbolName).foregroundStyle(NotchAIStyle.gradient)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                status
            }
            if run.isBusy {
                NotchAIProgressLine().transition(.opacity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    answer
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id(Self.tail)
                }
                .scrollIndicators(.automatic)
                .onChange(of: run.output) {
                    guard run.isBusy else { return }
                    // Follow the text while it writes itself; once it is done
                    // the reader owns the scroll position.
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(Self.tail, anchor: .bottom) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(NotchControlSurface(cornerRadius: 16, interactive: false))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: run.isBusy)
    }

    @ViewBuilder private var answer: some View {
        if case let .failed(error) = run.phase, run.output.isEmpty {
            Label {
                Text(error.message(l10n.language))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: error == .cancelled ? "stop.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(error == .cancelled ? .white.opacity(0.5) : .orange)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.8))
        } else if run.phase == .loading {
            NotchAIPlaceholder()
                .padding(.top, 2)
                .transition(.opacity)
        } else if run.phase == .streaming {
            // The caret says the text is still arriving, which a pause in the
            // stream would otherwise make look finished.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                (Text(run.output) + Text(" ▍").foregroundStyle(NotchAIStyle.colors[0].opacity(on ? 0.9 : 0.15)))
                    .font(.system(size: 13))
                    .lineSpacing(3)
            }
        } else {
            Text(run.output)
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }

    private func heading(_ label: String, symbol: String) -> some View {
        Label(label, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var status: some View {
        switch run.phase {
        case .loading, .streaming:
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchAIStyle.gradient)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                Text(run.phase == .loading ? strings.statusThinking : strings.statusWriting)
                // A cold model takes tens of seconds; a clock that moves says
                // the wait is being spent rather than stuck.
                Text(run.startedAt, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityElement(children: .combine)
        case .finished:
            if let confirmation {
                Label(confirmation == .copied ? strings.copied : strings.replaced,
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        case let .failed(error):
            // The partial text is still on screen above, so the reason has to
            // be visible next to it rather than replacing it.
            if !run.output.isEmpty {
                Label(error.message(l10n.language), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            if run.isBusy {
                action(strings.stop, symbol: "stop.fill") { ai.cancel() }
            } else {
                action(strings.retry, symbol: "arrow.clockwise") { ai.retry() }
            }
            Spacer(minLength: 8)
            if run.canReplaceEntry {
                action(strings.replaceEntry, symbol: "arrow.left.arrow.right") {
                    ai.replaceEntry()
                    withAnimation(.easeOut(duration: 0.15)) { confirmation = .replaced }
                }
            }
            action(strings.copyResult, symbol: "doc.on.doc", prominent: true) {
                ai.copyResult()
                withAnimation(.easeOut(duration: 0.15)) { confirmation = .copied }
            }
            .disabled(run.phase != .finished)
        }
    }

    private func action(_ label: String, symbol: String, prominent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(label, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(prominent ? AnyShapeStyle(.white.opacity(0.92))
                                      : AnyShapeStyle(.white.opacity(0.1)),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 9, lifts: false))
        .help(label)
    }

    private static let tail = "clipboardAI.tail"
}

/// As tall as its content wants, up to `maximum`. A frame with a maximum
/// height takes the whole maximum whenever it is offered, however short the
/// content inside it is.
private struct CappedHeight: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maximum))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
