// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import Foundation

/// A note as the list sees it. The body lives in its own file beside the
/// index, so drawing the list never opens a note that is not on screen; the
/// plain text kept here is what the title, the preview and search read.
struct NoteEntry: Codable, Equatable, Identifiable {
    let id: UUID
    /// Set only when the note was renamed. Otherwise the first line names it,
    /// the way Notes does, and the name follows the text as it changes.
    var customTitle: String?
    var text: String
    let createdAt: Date
    var modifiedAt: Date
    /// Pinned notes stay above the rest of the list, whatever was edited last.
    var pinned = false
}

extension NoteEntry {
    private enum CodingKeys: String, CodingKey {
        case id, customTitle, text, createdAt, modifiedAt, pinned
    }

    /// An index written before pinning existed has no `pinned` field; those
    /// notes read as unpinned instead of failing the whole index.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

struct NotesIndex: Codable, Equatable {
    var notes: [NoteEntry]
    var selectedID: UUID?

    static let empty = NotesIndex(notes: [], selectedID: nil)

    /// A repeated id keeps its first copy, the list comes back most recent
    /// first, and a selection naming no note falls back to the newest one.
    func sanitized() -> NotesIndex {
        var seen = Set<UUID>()
        let unique = notes.filter { seen.insert($0.id).inserted }.map { note -> NoteEntry in
            var note = note
            note.customTitle = note.customTitle.flatMap(NotesSupport.sanitizedTitle)
            return note
        }
        let ordered = NotesSupport.ordered(unique)
        let selection = ordered.contains { $0.id == selectedID } ? selectedID : ordered.first?.id
        return NotesIndex(notes: ordered, selectedID: selection)
    }
}

enum NoteListKind: Equatable {
    case bullet, numbered, checklist
}

/// The marker a list paragraph starts with. Lists are ordinary characters at
/// the start of a paragraph, so they survive copy, paste and plain text.
struct NoteLineMarker: Equatable {
    let kind: NoteListKind
    /// UTF-16 length of the marker and the space after it.
    let length: Int
    var number = 1
    var checked = false
}

enum NoteDateStyle: Equatable {
    case time, yesterday, weekday, date
}

enum NotesSupport {
    static let maximumTitleLength = 80
    static let maximumPreviewLength = 140
    static let bulletMarker = "• "
    static let uncheckedMarker = "☐ "
    static let checkedMarker = "☑ "
    /// What an image or a file leaves in the plain text of a note.
    private static let attachmentCharacter: Character = "\u{FFFC}"

    /// Pinned notes first, then most recently edited first, which is the
    /// order Notes lists them in.
    static func ordered(_ notes: [NoteEntry]) -> [NoteEntry] {
        notes.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Lines that hold words, with list markers and attachments left out.
    static func contentLines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = String(raw)
            if let marker = marker(of: line) { line = (line as NSString).substring(from: marker.length) }
            line.removeAll { $0 == attachmentCharacter }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func title(of note: NoteEntry, untitled: String) -> String {
        if let custom = note.customTitle { return custom }
        let first = contentLines(of: note.text).first.map { String($0.prefix(maximumTitleLength)) } ?? ""
        return first.isEmpty ? untitled : first
    }

    /// The line under the title. A renamed note no longer spends its first
    /// line on the name, so that line is what it previews.
    static func preview(of note: NoteEntry) -> String {
        let lines = contentLines(of: note.text)
        let line = note.customTitle == nil ? lines.dropFirst().first : lines.first
        return line.map { String($0.prefix(maximumPreviewLength)) } ?? ""
    }

    /// Whitespace collapses to single spaces and the length is capped. An
    /// empty name hands the title back to the note's first line.
    static func sanitizedTitle(_ proposed: String) -> String? {
        let words = proposed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let name = String(words.joined(separator: " ").prefix(maximumTitleLength))
        return name.isEmpty ? nil : name
    }

    /// Nothing but whitespace and list markers, which is how a note starts.
    /// An image counts as content even though it has no words.
    static func isBlank(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).allSatisfy { raw in
            let line = String(raw)
            let rest = marker(of: line).map { (line as NSString).substring(from: $0.length) } ?? line
            return rest.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static func matches(_ note: NoteEntry, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return (note.customTitle ?? "").range(of: needle, options: options) != nil
            || note.text.range(of: needle, options: options) != nil
    }

    /// The note that takes the place of one being removed: the one after it,
    /// or the one before it when it was last.
    static func selection(afterRemoving id: UUID, from ordered: [UUID]) -> UUID? {
        let rest = ordered.filter { $0 != id }
        guard let index = ordered.firstIndex(of: id) else { return rest.first }
        guard !rest.isEmpty else { return nil }
        return rest[min(index, rest.count - 1)]
    }

    /// Today shows the time, yesterday says so, the rest of the last week
    /// names the day, and anything older shows the date.
    static func dateStyle(for date: Date, now: Date, calendar: Calendar) -> NoteDateStyle {
        if calendar.isDate(date, inSameDayAs: now) { return .time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           date >= weekStart, date < now { return .weekday }
        return .date
    }

    // MARK: - Lists

    static func marker(of line: String) -> NoteLineMarker? {
        if line.hasPrefix(bulletMarker) { return NoteLineMarker(kind: .bullet, length: bulletMarker.utf16.count) }
        if line.hasPrefix(uncheckedMarker) {
            return NoteLineMarker(kind: .checklist, length: uncheckedMarker.utf16.count)
        }
        if line.hasPrefix(checkedMarker) {
            return NoteLineMarker(kind: .checklist, length: checkedMarker.utf16.count, checked: true)
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...4).contains(digits.count), let number = Int(digits), number > 0,
              line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return NoteLineMarker(kind: .numbered, length: digits.count + 2, number: number)
    }

    static func markerText(_ kind: NoteListKind, number: Int = 1, checked: Bool = false) -> String {
        switch kind {
        case .bullet: return bulletMarker
        case .numbered: return "\(max(1, number)). "
        case .checklist: return checked ? checkedMarker : uncheckedMarker
        }
    }

    enum Continuation: Equatable {
        /// Not a list line: Return is an ordinary new line.
        case none
        /// The new line starts with this marker.
        case next(String)
        /// Return on an empty item ends the list, so its marker goes instead.
        case end(markerLength: Int)
    }

    static func continuation(of line: String) -> Continuation {
        guard let marker = marker(of: line) else { return .none }
        let rest = (line as NSString).substring(from: marker.length)
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .end(markerLength: marker.length)
        }
        return .next(markerText(marker.kind, number: marker.number + 1))
    }

    /// What each paragraph's marker becomes when a run of them is switched to
    /// `kind`: the old marker's length is removed and the new text inserted.
    /// When every line is already that kind, the list is switched off, the
    /// way the list buttons toggle in Notes.
    static func toggledMarkers(for lines: [String], kind: NoteListKind) -> [(removing: Int, inserting: String)] {
        let markers = lines.map(marker(of:))
        let alreadyThatKind = !lines.isEmpty && markers.allSatisfy { $0?.kind == kind }
        var number = 0
        return markers.map { marker in
            if alreadyThatKind { return (marker?.length ?? 0, "") }
            number += 1
            return (marker?.length ?? 0, markerText(kind, number: number))
        }
    }

    /// The flipped checkbox for a checklist line, or nil when it has none.
    static func toggledCheckbox(of line: String) -> String? {
        guard let marker = marker(of: line), marker.kind == .checklist else { return nil }
        return markerText(.checklist, checked: !marker.checked)
    }

    /// Typing a space after one of these at the start of a paragraph turns it
    /// into a list item, the shortcut Notes also accepts.
    static func autoMarker(forPrefix prefix: String) -> String? {
        switch prefix {
        case "-", "*": return bulletMarker
        case "[]": return uncheckedMarker
        default: return nil
        }
    }
}
