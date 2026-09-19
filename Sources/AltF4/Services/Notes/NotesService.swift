// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import AppKit
import Combine

/// Owns the notes: which exist, which one is open, and getting every edit to
/// disk. The notch page only draws what is published here.
final class NotesService: ObservableObject {
    static let shared = NotesService()

    /// Pinned first, then most recently edited first.
    @Published private(set) var notes: [NoteEntry] = []
    @Published private(set) var selectedID: UUID?
    @Published var query = ""
    /// The index would not read. Nothing is written for the rest of the
    /// session, so a bad read never costs the notes behind it.
    @Published private(set) var unreadable = false
    /// Bumped when the open note should take the caret, as a new one does.
    @Published private(set) var focusRequest = 0

    private var store = NotesStore(directoryURL: PrivateFileStore.containerURL?
        .appendingPathComponent("Notes", isDirectory: true))
    private var loaded = false
    private var suspended = false
    private var bodies: [UUID: NSAttributedString] = [:]
    /// Bodies whose file is there but would not read. They are never written
    /// over; deleting the note is the only thing that touches them.
    private var lockedIDs = Set<UUID>()
    private var unsavedIDs = Set<UUID>()
    private var saveWork: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    private init() {}

    var visibleNotes: [NoteEntry] { notes.filter { NotesSupport.matches($0, query: query) } }
    var selectedNote: NoteEntry? { notes.first { $0.id == selectedID } }

    func prepare() {
        guard !loaded else { return }
        loaded = true
        do {
            let index = try store.loadIndex()
            notes = index.notes
            selectedID = index.selectedID
        } catch {
            unreadable = true
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flush()
        }
    }

    func create() {
        prepare()
        guard !unreadable else { return }
        flush()
        discardSelectedIfBlank()
        query = ""
        let now = Date()
        let note = NoteEntry(id: UUID(), customTitle: nil, text: "", createdAt: now, modifiedAt: now)
        notes = NotesSupport.ordered(notes + [note])
        bodies[note.id] = NSAttributedString()
        selectedID = note.id
        focusRequest &+= 1
        scheduleSave()
    }

    func select(_ id: UUID) {
        guard id != selectedID, notes.contains(where: { $0.id == id }) else { return }
        flush()
        discardSelectedIfBlank()
        selectedID = id
        scheduleSave()
    }

    func isLocked(_ id: UUID) -> Bool { lockedIDs.contains(id) }

    func body(for id: UUID) -> NSAttributedString {
        if let body = bodies[id] { return body }
        guard let body = store.loadBody(for: id) else {
            lockedIDs.insert(id)
            return NSAttributedString()
        }
        bodies[id] = body
        return body
    }

    func update(_ id: UUID, body: NSAttributedString) {
        guard !lockedIDs.contains(id), let index = notes.firstIndex(where: { $0.id == id }) else { return }
        bodies[id] = body
        var updated = notes
        updated[index].text = body.string
        updated[index].modifiedAt = Date()
        notes = NotesSupport.ordered(updated)
        unsavedIDs.insert(id)
        scheduleSave()
    }

    func rename(_ id: UUID, to proposed: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let title = NotesSupport.sanitizedTitle(proposed)
        guard notes[index].customTitle != title else { return }
        notes[index].customTitle = title
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var updated = notes
        updated[index].pinned.toggle()
        notes = NotesSupport.ordered(updated)
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        let replacement = NotesSupport.selection(afterRemoving: id, from: visibleNotes.map(\.id))
        notes.removeAll { $0.id == id }
        bodies[id] = nil
        unsavedIDs.remove(id)
        lockedIDs.remove(id)
        store.removeBody(for: id)
        if selectedID == id { selectedID = replacement ?? notes.first?.id }
        flush()
    }

    /// Leaving the page drops a note that was opened and left empty, and
    /// writes the rest now rather than after the save delay.
    func close() {
        guard loaded else { return }
        discardSelectedIfBlank()
        flush()
    }

    /// Uninstalling removes the notes directory, so nothing may write it back
    /// afterwards, including the save that runs as the app quits.
    func suspend() {
        saveWork?.cancel(); saveWork = nil
        suspended = true
    }

    /// Writes whatever is waiting. Also run when the app quits, so the last
    /// keystrokes before Quit are not lost to the save delay.
    func flush() {
        saveWork?.cancel(); saveWork = nil
        guard loaded, !unreadable, !suspended else { return }
        for id in unsavedIDs {
            if let body = bodies[id], store.saveBody(body, for: id) { unsavedIDs.remove(id) }
        }
        store.saveIndex(NotesIndex(notes: notes, selectedID: selectedID))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Notes throws away a note that was created and left without a word,
    /// so starting one by accident never leaves an empty entry behind.
    private func discardSelectedIfBlank() {
        guard let id = selectedID, let note = notes.first(where: { $0.id == id }),
              note.customTitle == nil, !note.pinned, NotesSupport.isBlank(note.text),
              !lockedIDs.contains(id) else { return }
        notes.removeAll { $0.id == id }
        bodies[id] = nil
        unsavedIDs.remove(id)
        store.removeBody(for: id)
        selectedID = notes.first?.id
    }
}
