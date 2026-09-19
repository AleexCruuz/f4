// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Home: live cards for what is happening now, then every module and the app
/// panel. A search replaces both with a plain list of matching modules.
struct NotchSectionsView: View {
    @ObservedObject var service: NotchService
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var calendar = NotchCalendarService.shared
    @ObservedObject private var timer = NotchTimerService.shared
    @FocusState private var searching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var text: NotchStrings { FeatureStrings.notch(l10n.language) }
    private var sections: [NotchModule] { service.filteredSections }
    private var isHome: Bool { service.sectionQuery.isEmpty }
    private var panoramic: Bool { service.geometry.isPanoramic }
    private var locale: Locale { Locale(identifier: l10n.language.rawValue) }

    var body: some View {
        VStack(spacing: 12) {
            searchField

            if !isHome && sections.isEmpty {
                NotchEmptyView(symbol: "magnifyingglass", message: FeatureStrings.clipboard(l10n.language).noResults)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            if isHome {
                                VStack(spacing: NotchLayout.sectionSpacing) {
                                    cards
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NotchLayout.sectionSpacing),
                                                              count: panoramic ? max(1, sections.count) : service.geometry.sectionColumns),
                                              spacing: NotchLayout.sectionSpacing) {
                                        ForEach(sections) { module in tile(module).id(module) }
                                    }
                                }
                            } else {
                                LazyVStack(spacing: NotchLayout.sectionSpacing) {
                                    ForEach(sections) { module in tile(module).id(module) }
                                }
                            }
                        }
                        .padding(2)
                    }
                    .scrollIndicators(.automatic)
                    .onAppear {
                        if let target = service.highlightedSection, !isHome { proxy.scrollTo(target, anchor: .center) }
                    }
                    .onChange(of: service.highlightedSection) { _, target in
                        guard let target else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { searching = true }
        .onChange(of: sections) { _, visible in
            if let current = service.highlightedSection, !visible.contains(current) {
                service.highlightedSection = service.sectionQuery.isEmpty ? nil : visible.first
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(text.searchSections, text: Binding(get: { service.sectionQuery }, set: service.searchSections))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searching)
                .accessibilityLabel(text.searchSections)
            if !service.sectionQuery.isEmpty {
                Button { service.searchSections(""); searching = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.s.actionClear)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NotchLayout.sectionSearchHeight)
        .background(.white.opacity(NotchFill.card), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Live cards

    private var cards: some View {
        let rows = NotchHomeCard.rows(for: service.modules, panoramic: panoramic)
        return ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            HStack(spacing: NotchLayout.sectionSpacing) {
                ForEach(row, id: \.self) { card in
                    if panoramic {
                        switch card {
                        case .music: NotchMusicControlsView(notch: service, height: NotchLayout.panoramicCardHeight, artworkSize: 92)
                        case .system: panoramicSystemCard.frame(maxWidth: row.contains(.music) ? 160 : .infinity)
                        case .calendar: panoramicCalendarCard.frame(maxWidth: row.contains(.music) ? 132 : .infinity)
                        case .timer: panoramicTimerCard.frame(maxWidth: row.contains(.music) ? 132 : .infinity)
                        }
                    } else {
                        switch card {
                        case .music: NotchMusicControlsView(notch: service)
                        case .system: systemCard.frame(maxWidth: row.contains(.music) ? 124 : .infinity)
                        case .calendar: calendarCard
                        case .timer: timerCard
                        }
                    }
                }
            }
            .frame(height: NotchHomeCard.rowHeight(row, panoramic: panoramic))
        }
    }

    private var memoryFraction: Double? {
        let snapshot = monitor.snapshot
        return snapshot.memoryUsed.flatMap { used in
            snapshot.memoryTotal.flatMap { total in total > 0 ? Double(used) / Double(total) : nil }
        }
    }

    private func percent(_ value: Double?) -> String {
        value.flatMap { $0.isFinite ? "\(Int((min(1, max(0, $0)) * 100).rounded()))%" : nil } ?? "–"
    }

    private var systemCard: some View {
        card(module: .system) {
            VStack(alignment: .leading, spacing: 10) {
                if AppFeature.monitorCPU.isAvailable {
                    reading(l10n.s.cpuLabel, monitor.snapshot.cpuUsage)
                }
                if AppFeature.monitorMemory.isAvailable {
                    reading(l10n.s.memorySection, memoryFraction)
                }
            }
        }
    }

    private func reading(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(percent(value))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            NotchMeter(value: value ?? 0, height: 4)
        }
    }

    // MARK: - Panoramic cards

    private var panoramicSystemCard: some View {
        let snapshot = monitor.snapshot
        return card(module: .system) {
            VStack(alignment: .leading, spacing: 8) {
                if AppFeature.monitorCPU.isAvailable {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(percent(snapshot.cpuUsage))
                            .font(.system(size: 24, weight: .bold)).monospacedDigit()
                        Text(l10n.s.cpuLabel)
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Sparkline(values: snapshot.cpuHistory, color: .white, maxValue: 1, fillOpacity: 0.3)
                        .frame(maxHeight: .infinity)
                }
                if AppFeature.monitorMemory.isAvailable {
                    reading(l10n.s.memorySection, memoryFraction)
                }
            }
            .padding(.vertical, 14)
        }
    }

    private var panoramicCalendarCard: some View {
        let strings = FeatureStrings.notchCalendar(l10n.language)
        let next = NotchCalendarSupport.next(calendar.events, now: Date())
        let today = Date()
        return card(module: .calendar) {
            VStack(alignment: .leading, spacing: 0) {
                Text(today.formatted(.dateTime.weekday(.wide).locale(locale)).capitalized(with: locale))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Text(today.formatted(.dateTime.day().locale(locale)))
                    .font(.system(size: 34, weight: .bold)).monospacedDigit()
                Spacer(minLength: 4)
                HStack(spacing: 7) {
                    Capsule(style: .continuous).fill(.white).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.map { $0.title.isEmpty ? strings.untitled : $0.title } ?? strings.empty)
                            .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        if let next {
                            Text(next.allDay ? strings.allDay : next.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 14)
        }
    }

    private var panoramicTimerCard: some View {
        let session = timer.session
        return card(module: .timer) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: session.countsUp ? "stopwatch" : NotchModule.timer.symbol)
                    .font(.system(size: 20, weight: .medium))
                Spacer(minLength: 4)
                if session.hasSession {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(NotchTimerSupport.compactText(for: session, at: timer.now, locale: locale))
                            .font(.system(size: 22, weight: .bold)).monospacedDigit().lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    Text(NotchModule.timer.title(l10n.language))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
            }
            .padding(.vertical, 14)
        }
    }

    private var calendarCard: some View {
        let strings = FeatureStrings.notchCalendar(l10n.language)
        let next = NotchCalendarSupport.next(calendar.events, now: Date())
        return card(module: .calendar) {
            HStack(spacing: 10) {
                Image(systemName: NotchModule.calendar.symbol)
                    .font(.system(size: 17, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.map { $0.title.isEmpty ? strings.untitled : $0.title } ?? strings.empty)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let next {
                        Text(next.allDay ? strings.allDay : next.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var timerCard: some View {
        let session = timer.session
        return card(module: .timer) {
            HStack(spacing: 10) {
                Image(systemName: session.countsUp ? "stopwatch" : NotchModule.timer.symbol)
                    .font(.system(size: 17, weight: .medium))
                if session.hasSession {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(NotchTimerSupport.compactText(for: session, at: timer.now,
                                                            locale: Locale(identifier: l10n.language.rawValue)))
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    }
                } else {
                    Text(NotchModule.timer.title(l10n.language))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func card<Content: View>(module: NotchModule, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { service.select(module) } label: {
            content()
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(.white.opacity(NotchFill.card), in: shape)
                .overlay { shape.strokeBorder(.white.opacity(contrast == .increased ? 0.4 : 0.04), lineWidth: 1) }
                .contentShape(shape)
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 16, lifts: false))
        .accessibilityLabel(module.title(l10n.language))
    }

    // MARK: - Modules

    private func tile(_ module: NotchModule) -> some View {
        let asRow = !isHome
        let docked = isHome && panoramic
        let highlighted = service.highlightedSection == module
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { service.select(module) } label: {
            Group {
                if docked {
                    Image(systemName: module.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                } else {
                    tileLabel(symbol: module.symbol, title: module.title(l10n.language), asRow: asRow)
                }
            }
            .padding(.horizontal, asRow ? 14 : 6)
            .frame(maxWidth: .infinity)
            .frame(height: asRow ? NotchLayout.sectionResultHeight
                   : docked ? NotchLayout.dockTileHeight : NotchLayout.sectionTileHeight)
            .background(.white.opacity(highlighted ? NotchFill.selected : NotchFill.quiet), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(highlighted ? 0.55 : contrast == .increased ? 0.4 : 0.04), lineWidth: 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 16, lifts: false))
        .accessibilityLabel(module.title(l10n.language))
        .accessibilityIdentifier("notch.module.\(module.rawValue)")
        .help(module.title(l10n.language))
    }

    private func tileLabel(symbol: String, title: String, asRow: Bool) -> some View {
        let layout = asRow ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 6))
        return layout {
            Image(systemName: symbol)
                .font(.system(size: asRow ? 18 : 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(asRow ? 1 : 2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(asRow ? .leading : .center)
                .frame(maxWidth: asRow ? .infinity : nil, alignment: asRow ? .leading : .center)
        }
    }
}
