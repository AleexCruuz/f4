// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import SwiftUI

/// The footer below the camera: the microphone level with no smoothing to
/// wait for, motion while the engines work, then the outcome's symbol.
struct NotchDictationActivity: View {
    let notice: NotchNotice
    let height: CGFloat
    @ObservedObject private var dictation = DictationService.shared

    var body: some View {
        Group {
            if let action = notice.actionTitle {
                NotchDictationOffer(message: notice.title, action: action, symbol: notice.symbol)
            } else if dictation.phase.isRecording {
                let bars = DictationNoticeLayout.bars(from: dictation.levels, count: DictationService.meterBars)
                let tallest = max(4, height - 8)
                HStack(spacing: 2.5) {
                    ForEach(bars.indices, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.92))
                            .frame(width: 3, height: max(3, tallest * CGFloat(bars[index])))
                    }
                }
                .animation(.linear(duration: 0.03), value: bars)
            } else if dictation.phase.isProcessing {
                NotchEqualizerBars(bars: 5, barWidth: 2.5, height: max(4, height - 12),
                                   tint: .white.opacity(0.8))
            } else {
                Image(systemName: notice.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var tint: Color {
        switch dictation.phase {
        case .finished(.pasted): return .green
        case .failed: return .orange
        default: return .white
        }
    }
}

/// The text had nowhere to go: a line saying so and the copy, which a click
/// anywhere on the notice takes. It drops out from under the cutout as the
/// notice grows to hold it.
private struct NotchDictationOffer: View {
    let message: String
    let action: String
    let symbol: String
    @State private var shown = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            Label(action, systemImage: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.white.opacity(hovered ? 1 : 0.9), in: Capsule())
                .scaleEffect(hovered && !reduceMotion ? 1.04 : 1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .offset(y: shown || reduceMotion ? 0 : -10)
        .opacity(shown ? 1 : 0)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.2).delay(0.05)) {
                shown = true
            }
        }
    }
}

