// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct NotchClipboardView: View {
    let service: NotchService
    @ObservedObject private var history = ClipboardHistoryService.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var ai = ClipboardAIService.shared
    @State private var query = ""
    @State private var copiedID: UUID?
    @State private var pinnedOnly = false
    /// The one row whose AI actions are open. Opening another closes it.
    @State private var trayID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var text: ClipboardFeatureStrings { FeatureStrings.clipboard(l10n.language) }

    private var entries: [ClipboardHistoryEntry] {
        history.filteredEntries(matching: query).filter { !pinnedOnly || $0.isPinned }
    }

    var body: some View {
        Group {
            // A run owns the page while it exists. The trail in the header is
            // the way back, and leaving by it is what ends the run.
            if let run = ai.run, run.module == .clipboard {
                NotchClipboardAIView(run: run)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: copiedID) {
            // The tick confirms one copy; leaving it on the row forever would
            // read as a permanent state instead of an answer.
            guard copiedID != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            copiedID = nil
        }
    }

    private var list: some View {
        VStack(spacing: 14) {
            searchField
            if entries.isEmpty {
                NotchEmptyView(symbol: pinnedOnly ? "pin" : "doc.on.clipboard",
                               message: query.isEmpty && !pinnedOnly ? text.empty : text.noResults)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(entries) { entry in
                                row(entry).id(entry.id)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: trayID) {
                        guard let trayID else { return }
                        // The tray grows the row downwards; the last rows
                        // would otherwise open it below the visible edge.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(trayID) }
                        }
                    }
                }
            }
        }
    }

    // The pop-out button that moved this list into a floating window is gone.
    // It was a second home for the same list, reachable from the one place the
    // list already was, and it took the row that search and pinning share.
    private var searchField: some View {
        NotchListSearchField(prompt: text.search, query: $query) {
            NotchRowAction(symbol: pinnedOnly ? "pin.fill" : "pin", title: text.pinned, active: pinnedOnly) {
                pinnedOnly.toggle()
            }
            NotchRowAction(symbol: "trash", title: text.clearRecent, role: .destructive) {
                withAnimation(motion) { history.clearRecent() }
                copiedID = nil
            }
            .disabled(history.recentEntries.isEmpty)
        }
    }

    private func row(_ entry: ClipboardHistoryEntry) -> some View {
        let trayOpen = trayID == entry.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // The row is a shortcut for pasting, not a control to aim at:
                // it answers a press but never lights up under the pointer.
                Button {
                    if permissions.accessibility {
                        service.collapse()
                        history.copyQuickEntry(entry)
                    } else {
                        copy(entry)
                    }
                } label: {
                    HStack(spacing: 12) {
                        preview(entry)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.kind == .image ? text.imageEntryLabel : entry.preview)
                                .font(.system(size: 12.5))
                                .lineSpacing(1.5)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            meta(entry)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressStyle())
                .help(text.copy)
                HStack(spacing: 2) {
                    if ai.canRun(on: entry) {
                        NotchRowAction(symbol: "sparkles", title: FeatureStrings.clipboardAI(l10n.language).title,
                                       role: .accent, active: trayOpen) {
                            withAnimation(motion) { trayID = trayOpen ? nil : entry.id }
                        }
                    }
                    NotchRowAction(symbol: entry.isPinned ? "pin.fill" : "pin",
                                   title: entry.isPinned ? text.unpin : text.pin, active: entry.isPinned) {
                        withAnimation(motion) { history.togglePin(entry) }
                    }
                    NotchRowAction(symbol: "trash", title: text.delete, role: .destructive) {
                        remove(entry)
                    }
                }
            }
            if trayOpen {
                NotchAIActionTray { action in
                    trayID = nil
                    ai.start(action, on: entry)
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .padding(.vertical, 11)
        .modifier(NotchControlSurface(cornerRadius: 16, selected: entry.isPinned, interactive: false))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .contextMenu {
            // Moving only means something in the full list; inside a search
            // or the pinned filter the neighbours on screen are not the ones
            // the entry would swap with.
            let reorders = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pinnedOnly
            Button(text.moveUp) { history.move(entry, .up) }
                .disabled(!reorders || !history.canMove(entry, .up))
            Button(text.moveDown) { history.move(entry, .down) }
                .disabled(!reorders || !history.canMove(entry, .down))
            Divider()
            Button(text.delete, role: .destructive) { remove(entry) }
        }
    }

    @ViewBuilder private func meta(_ entry: ClipboardHistoryEntry) -> some View {
        if copiedID == entry.id {
            Label(text.copied, systemImage: "checkmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .transition(.opacity)
        } else {
            Text(entry.copiedAt, style: .time)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }

    private func remove(_ entry: ClipboardHistoryEntry) {
        if trayID == entry.id { trayID = nil }
        withAnimation(motion) { history.remove(entry) }
    }

    private func copy(_ entry: ClipboardHistoryEntry) {
        history.copy(entry) { copied in
            if copied {
                withAnimation(.easeOut(duration: 0.15)) { copiedID = entry.id }
            } else {
                NSSound.beep()
            }
        }
    }

    @ViewBuilder private func preview(_ entry: ClipboardHistoryEntry) -> some View {
        if entry.kind == .image, let name = entry.imageFile,
           let image = ClipboardImageStore.thumbnail(named: name) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 40, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: entry.kind == .files ? "doc" : "text.alignleft")
                .foregroundStyle(.secondary).frame(width: 26)
        }
    }
}
