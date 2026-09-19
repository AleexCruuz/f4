// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import SwiftUI

/// Every dictation this Mac has delivered, newest first, a day at a time.
struct NotchDictationHistoryView: View {
    @ObservedObject private var history = DictationHistoryService.shared
    @ObservedObject private var ai = ClipboardAIService.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var query = ""
    @State private var copiedID: UUID?
    @State private var trayID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var text: DictationStrings { FeatureStrings.dictation(l10n.language) }

    private var days: [DictationHistory.Day] {
        DictationHistory.days(DictationHistory.filtered(history.records, matching: query), calendar: .current)
    }

    var body: some View {
        Group {
            if let run = ai.run, run.module == .dictation {
                NotchClipboardAIView(run: run)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, Locale(identifier: l10n.language.rawValue))
        .task(id: copiedID) {
            guard copiedID != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            copiedID = nil
        }
    }

    private var list: some View {
        VStack(spacing: 14) {
            NotchListSearchField(prompt: text.historySearch, query: $query) { EmptyView() }
            let days = days
            if days.isEmpty {
                NotchEmptyView(symbol: "mic", message: query.isEmpty ? text.historyEmpty : text.historyNoResults)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                                header(day, first: index == 0)
                                ForEach(day.records) { record in
                                    row(record).id(record.id)
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: trayID) {
                        guard let trayID else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(trayID) }
                        }
                    }
                }
            }
        }
    }

    private func header(_ day: DictationHistory.Day, first: Bool) -> some View {
        HStack(spacing: 6) {
            Text(dayTitle(day.start))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
            Spacer(minLength: 8)
            Label(DictationHistory.durationLabel(day.duration), systemImage: "waveform")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 4)
        .padding(.top, first ? 0 : 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ record: DictationRecord) -> some View {
        let trayOpen = trayID == record.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { copy(record) } label: {
                    HStack(spacing: 12) {
                        durationBadge(record)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.text)
                                .font(.system(size: 12.5))
                                .lineSpacing(1.5)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            meta(record)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressStyle())
                .help(text.copy)
                HStack(spacing: 2) {
                    if ai.canRun(on: record) {
                        NotchRowAction(symbol: "sparkles", title: FeatureStrings.clipboardAI(l10n.language).menuLabel,
                                       role: .accent, active: trayOpen) {
                            withAnimation(motion) { trayID = trayOpen ? nil : record.id }
                        }
                    }
                    NotchRowAction(symbol: copiedID == record.id ? "checkmark" : "doc.on.doc",
                                   title: copiedID == record.id ? text.statusCopied : text.copy,
                                   active: copiedID == record.id) {
                        copy(record)
                    }
                    NotchRowAction(symbol: "trash", title: text.historyDelete, role: .destructive) {
                        remove(record)
                    }
                }
            }
            if trayOpen {
                NotchAIActionTray { action in
                    trayID = nil
                    ai.start(action, on: record)
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .padding(.vertical, 11)
        .modifier(NotchControlSurface(cornerRadius: 16, interactive: false))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .contextMenu {
            Button(text.copy) { copy(record) }
            Divider()
            Button(text.historyDelete, role: .destructive) { remove(record) }
        }
    }

    private func durationBadge(_ record: DictationRecord) -> some View {
        VStack(spacing: 3) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(DictationHistory.durationLabel(record.duration))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(width: 42, height: 40)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private func meta(_ record: DictationRecord) -> some View {
        if copiedID == record.id {
            Label(text.statusCopied, systemImage: "checkmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .transition(.opacity)
        } else {
            HStack(spacing: 5) {
                Text(record.date, style: .time)
                if let app = record.appName {
                    Text("·")
                    Text(app).lineLimit(1)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: l10n.language.rawValue)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }

    private func copy(_ record: DictationRecord) {
        history.copy(record)
        withAnimation(.easeOut(duration: 0.15)) { copiedID = record.id }
    }

    private func remove(_ record: DictationRecord) {
        if trayID == record.id { trayID = nil }
        withAnimation(motion) { history.remove(record) }
    }
}
