// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import SwiftUI

/// Notes in the notch: the list on the left and the open note beside it, the
/// same two columns as the Notes app, sized to the notch's content area.
struct NotchNotesView: View {
    let size: CGSize
    @ObservedObject private var notes = NotesService.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var editor = NotesEditorController()
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var pendingDeletion: NoteEntry?
    @FocusState private var searching: Bool
    @FocusState private var renaming: Bool
    private var text: NotesStrings { FeatureStrings.notes(l10n.language) }
    private static let listWidth: CGFloat = 214

    var body: some View {
        Group {
            if notes.unreadable {
                NotchEmptyView(symbol: "exclamationmark.triangle", message: text.unreadable)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    sidebar.frame(width: Self.listWidth)
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 0.5)
                    editorColumn
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onAppear { notes.prepare() }
        .onDisappear { notes.close() }
        .onChange(of: searching) { _, active in
            if active { NotchService.shared.keepOpenForTyping() }
        }
        .confirmationDialog(text.deleteTitle, isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { note in
            Button(text.delete, role: .destructive) { notes.delete(note.id) }
            Button(text.cancel, role: .cancel) {}
        } message: { _ in
            Text(text.deleteMessage)
        }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                searchField
                NotchIconButton(symbol: "square.and.pencil", title: text.newNote) { notes.create() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            let visible = notes.visibleNotes
            if notes.notes.isEmpty || visible.isEmpty {
                Text(notes.notes.isEmpty ? text.empty : text.noResults)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let pinned = visible.filter(\.pinned)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Headings appear only once something is pinned, the
                        // way Notes splits its list.
                        if !pinned.isEmpty {
                            sectionHeader(text.pinned)
                            ForEach(pinned) { row($0) }
                            sectionHeader(text.title).padding(.top, 8)
                        }
                        ForEach(visible.filter { !$0.pinned }) { row($0) }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(text.search, text: $notes.query).textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searching)
                .accessibilityLabel(text.search)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .modifier(NotchControlSurface(cornerRadius: 12))
    }

    @ViewBuilder
    private func row(_ note: NoteEntry) -> some View {
        let selected = note.id == notes.selectedID
        if renamingID == note.id {
            TextField(text.rename, text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .focused($renaming)
                .onSubmit(commitRename)
                .onChange(of: renaming) { _, active in if !active { commitRename() } }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(.white.opacity(NotchFill.selected), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Button { notes.select(note.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if note.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.orange)
                                .accessibilityLabel(text.pinned)
                        }
                        Text(NotesSupport.title(of: note, untitled: text.untitled))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(dateLabel(note.modifiedAt)).foregroundStyle(.white.opacity(0.78))
                        Text(preview(note)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(selected ? NotchFill.selected : 0),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(NotchButtonStyle(cornerRadius: 10, lifts: false))
            .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(note) })
            .contextMenu {
                Button(note.pinned ? text.unpin : text.pin) { notes.togglePin(note.id) }
                Button(text.rename) { startRename(note) }
                Button(text.delete, role: .destructive) { requestDelete(note) }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func preview(_ note: NoteEntry) -> String {
        let line = NotesSupport.preview(of: note)
        return line.isEmpty ? text.noAdditionalText : line
    }

    private func dateLabel(_ date: Date) -> String {
        let locale = Locale(identifier: l10n.language.rawValue)
        switch NotesSupport.dateStyle(for: date, now: Date(), calendar: .current) {
        case .time: return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        case .yesterday: return text.yesterday
        case .weekday: return date.formatted(Date.FormatStyle().weekday(.wide).locale(locale))
        case .date: return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(locale))
        }
    }

    private func startRename(_ note: NoteEntry) {
        renameText = NotesSupport.title(of: note, untitled: text.untitled)
        renamingID = note.id
        NotchService.shared.keepOpenForTyping()
        DispatchQueue.main.async { renaming = true }
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        renamingID = nil
        notes.rename(id, to: renameText)
    }

    /// A note with nothing in it goes at once; anything else asks first.
    private func requestDelete(_ note: NoteEntry) {
        if NotesSupport.isBlank(note.text) { notes.delete(note.id) } else { pendingDeletion = note }
    }

    // MARK: Editor

    private var editorColumn: some View {
        VStack(spacing: 6) {
            toolbar
            if let note = notes.selectedNote {
                Text(note.modifiedAt.formatted(Date.FormatStyle(date: .long, time: .shortened)
                    .locale(Locale(identifier: l10n.language.rawValue))))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                NotesEditor(noteID: note.id, editable: !notes.isLocked(note.id), focusRequest: notes.focusRequest,
                            controller: editor, load: notes.body(for:), changed: notes.update(_:body:),
                            focused: { NotchService.shared.keepOpenForTyping() })
            } else {
                Spacer(minLength: 0)
                Button { notes.create() } label: {
                    Label(text.newNote, systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .modifier(NotchControlSurface(cornerRadius: 12))
                }
                .buttonStyle(NotchButtonStyle(cornerRadius: 12))
                .disabled(notes.unreadable)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Menu {
                Button(text.styleTitle) { editor.apply(.title) }
                Button(text.styleHeading) { editor.apply(.heading) }
                Button(text.styleBody) { editor.apply(.body) }
                Divider()
                Button(text.bold) { editor.toggle(.boldFontMask) }
                Button(text.italic) { editor.toggle(.italicFontMask) }
                Button(text.underline) { editor.toggleUnderline() }
                Button(text.strikethrough) { editor.toggleStrikethrough() }
            } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(text.format)
            .accessibilityLabel(text.format)
            NotchIconButton(symbol: "checklist", title: text.checklist) { editor.toggleList(.checklist) }
            NotchIconButton(symbol: "list.bullet", title: text.bulletedList) { editor.toggleList(.bullet) }
            NotchIconButton(symbol: "list.number", title: text.numberedList) { editor.toggleList(.numbered) }
            Spacer(minLength: 0)
            let pinned = notes.selectedNote?.pinned == true
            NotchIconButton(symbol: pinned ? "pin.fill" : "pin", title: pinned ? text.unpin : text.pin,
                            selected: pinned) {
                if let note = notes.selectedNote { notes.togglePin(note.id) }
            }
            NotchIconButton(symbol: "trash", title: text.delete) {
                if let note = notes.selectedNote { requestDelete(note) }
            }
        }
        .disabled(notes.selectedNote == nil)
    }
}
