// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import AppKit

/// Notes in the notch: how a note is named and listed, how its lists behave
/// as you type, and that what is written survives the trip to disk.
enum NotesTests {
    static func run(_ suite: TestSuite) {
        naming(suite)
        listing(suite)
        lists(suite)
        index(suite)
        store(suite)
        placement(suite)
    }

    private static func note(_ text: String, title: String? = nil, modified: TimeInterval = 0,
                             created: TimeInterval = 0) -> NoteEntry {
        NoteEntry(id: UUID(), customTitle: title, text: text,
                  createdAt: Date(timeIntervalSince1970: 1_800_000_000 + created),
                  modifiedAt: Date(timeIntervalSince1970: 1_800_000_000 + modified))
    }

    // MARK: - Names

    private static func naming(_ suite: TestSuite) {
        let groceries = note("\n  Groceries  \nMilk\nBread")
        suite.expect(NotesSupport.title(of: groceries, untitled: "New Note") == "Groceries"
                     && NotesSupport.preview(of: groceries) == "Milk",
                     "the first line with words names a note and the next one previews it")
        suite.expect(NotesSupport.title(of: note(""), untitled: "New Note") == "New Note"
                     && NotesSupport.preview(of: note("")) == "",
                     "an empty note shows the untitled name and no preview")
        suite.expect(NotesSupport.title(of: note("☐ Call the bank\n• Ask about fees"), untitled: "")
                     == "Call the bank",
                     "list markers never become part of a title")
        suite.expect(NotesSupport.title(of: note("\u{FFFC}\nHoliday photos"), untitled: "") == "Holiday photos",
                     "a line holding only an image is skipped when naming a note")
        let renamed = note("Groceries\nMilk", title: "Shopping")
        suite.expect(NotesSupport.title(of: renamed, untitled: "") == "Shopping"
                     && NotesSupport.preview(of: renamed) == "Groceries",
                     "a renamed note keeps its name and previews its first line instead")
        suite.expect(NotesSupport.title(of: note(String(repeating: "a", count: 200)), untitled: "").count
                     == NotesSupport.maximumTitleLength,
                     "a long first line is cut to the title length")
        suite.expect(NotesSupport.sanitizedTitle("  Trip \n  plans\t 2026 ") == "Trip plans 2026",
                     "a new name collapses its whitespace")
        suite.expect(NotesSupport.sanitizedTitle(" \n\t ") == nil,
                     "clearing a name hands the title back to the first line")
        suite.expect(NotesSupport.isBlank("") && NotesSupport.isBlank("  \n☐ \n• ")
                     && !NotesSupport.isBlank("\u{FFFC}") && !NotesSupport.isBlank("• milk"),
                     "only whitespace and bare markers make a note blank; an image is content")
    }

    // MARK: - The list

    private static func listing(_ suite: TestSuite) {
        let old = note("Old", modified: 10, created: 0)
        let recent = note("Recent", modified: 50, created: 5)
        let tie = note("Tie", modified: 50, created: 20)
        suite.expect(NotesSupport.ordered([old, recent, tie]).map(\.text) == ["Tie", "Recent", "Old"],
                     "the list shows the most recently edited note first, newest creation breaking ties")
        var pinned = note("Pinned", modified: 1)
        pinned.pinned = true
        suite.expect(NotesSupport.ordered([recent, pinned, old]).map(\.text) == ["Pinned", "Recent", "Old"],
                     "a pinned note stays above notes edited after it")
        let accented = note("Reunión con Élodie")
        suite.expect(NotesSupport.matches(accented, query: "reunion")
                     && NotesSupport.matches(accented, query: "ELODIE")
                     && !NotesSupport.matches(accented, query: "dentist")
                     && NotesSupport.matches(accented, query: "  "),
                     "search ignores case and accents, and a blank query matches everything")
        suite.expect(NotesSupport.matches(note("text", title: "Budget"), query: "budg"),
                     "search finds a note by the name it was given")
        let ids = [UUID(), UUID(), UUID()]
        suite.expect(NotesSupport.selection(afterRemoving: ids[1], from: ids) == ids[2]
                     && NotesSupport.selection(afterRemoving: ids[2], from: ids) == ids[1]
                     && NotesSupport.selection(afterRemoving: ids[0], from: [ids[0]]) == nil,
                     "deleting a note opens the one below it, or the one above at the end of the list")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 3_600
        let startOfToday = calendar.startOfDay(for: now)
        suite.expect(NotesSupport.dateStyle(for: startOfToday.addingTimeInterval(hour), now: now, calendar: calendar) == .time
                     && NotesSupport.dateStyle(for: startOfToday.addingTimeInterval(-hour), now: now, calendar: calendar) == .yesterday
                     && NotesSupport.dateStyle(for: startOfToday.addingTimeInterval(-3 * 24 * hour), now: now,
                                               calendar: calendar) == .weekday
                     && NotesSupport.dateStyle(for: startOfToday.addingTimeInterval(-9 * 24 * hour), now: now,
                                               calendar: calendar) == .date,
                     "dates read as a time today, yesterday, a weekday this week, and a date before that")
    }

    // MARK: - Lists while typing

    private static func lists(_ suite: TestSuite) {
        suite.expect(NotesSupport.marker(of: "• milk")?.kind == .bullet
                     && NotesSupport.marker(of: "☐ call")?.checked == false
                     && NotesSupport.marker(of: "☑ call")?.checked == true
                     && NotesSupport.marker(of: "12. step")?.number == 12
                     && NotesSupport.marker(of: "12. step")?.length == 4,
                     "each list marker is recognised with its kind, state and length")
        suite.expect(["1.2 pounds", "•milk", "0. zero", "12345. long", "no list", ""].allSatisfy {
            NotesSupport.marker(of: $0) == nil
        }, "text that only resembles a marker is not a list")
        suite.expect(NotesSupport.continuation(of: "• milk\n") == .next("• ")
                     && NotesSupport.continuation(of: "3. eggs") == .next("4. ")
                     && NotesSupport.continuation(of: "☑ done") == .next("☐ "),
                     "Return continues a list, counting up and starting each new task unticked")
        suite.expect(NotesSupport.continuation(of: "•  \n") == .end(markerLength: 2)
                     && NotesSupport.continuation(of: "10. ") == .end(markerLength: 4),
                     "Return on an empty item ends the list")
        suite.expect(NotesSupport.continuation(of: "plain line") == .none,
                     "Return outside a list is an ordinary new line")
        let added = NotesSupport.toggledMarkers(for: ["milk\n", "• eggs\n", "bread"], kind: .numbered)
        suite.expect(added.map(\.inserting) == ["1. ", "2. ", "3. "] && added.map(\.removing) == [0, 2, 0],
                     "a mixed selection becomes one numbered list, replacing any other marker")
        let removed = NotesSupport.toggledMarkers(for: ["☐ milk\n", "☑ eggs"], kind: .checklist)
        suite.expect(removed.map(\.inserting) == ["", ""] && removed.map(\.removing) == [2, 2],
                     "the list button switches a list off when every line is already that kind")
        suite.expect(NotesSupport.toggledCheckbox(of: "☐ call") == "☑ "
                     && NotesSupport.toggledCheckbox(of: "☑ call") == "☐ "
                     && NotesSupport.toggledCheckbox(of: "• call") == nil,
                     "a click ticks and unticks a task and leaves other lists alone")
        suite.expect(NotesSupport.autoMarker(forPrefix: "-") == NotesSupport.bulletMarker
                     && NotesSupport.autoMarker(forPrefix: "*") == NotesSupport.bulletMarker
                     && NotesSupport.autoMarker(forPrefix: "[]") == NotesSupport.uncheckedMarker
                     && NotesSupport.autoMarker(forPrefix: "--") == nil,
                     "typing - or [] and a space at the start of a line starts a list")
        suite.expect(NotesSupport.markerText(.numbered, number: 0) == "1. ",
                     "numbering never starts below one")
    }

    // MARK: - Index

    private static func index(_ suite: TestSuite) {
        let first = note("First", title: "  ", modified: 1)
        let second = note("Second", modified: 2)
        let duplicate = NoteEntry(id: first.id, customTitle: nil, text: "Copy", createdAt: first.createdAt,
                                  modifiedAt: first.modifiedAt)
        let clean = NotesIndex(notes: [first, second, duplicate], selectedID: UUID()).sanitized()
        suite.expect(clean.notes.map(\.text) == ["Second", "First"],
                     "a repeated id keeps its first copy and the list comes back newest first")
        suite.expect(clean.selectedID == second.id, "a selection naming no note falls back to the newest one")
        suite.expect(clean.notes.last?.customTitle == nil, "a blank stored name reads as no name")
        suite.expect(NotesIndex(notes: [first], selectedID: first.id).sanitized().selectedID == first.id,
                     "a valid selection is kept")
        var kept = note("Keep", modified: 3)
        kept.pinned = true
        let written = try? JSONEncoder().encode(NotesIndex(notes: [kept], selectedID: nil))
        suite.expect(written.flatMap { try? JSONDecoder().decode(NotesIndex.self, from: $0) }?.notes.first?.pinned == true,
                     "pinning is saved with the note")
        var legacy: NotesIndex?
        if let written, var object = try? JSONSerialization.jsonObject(with: written) as? [String: Any],
           var entries = object["notes"] as? [[String: Any]] {
            entries[0].removeValue(forKey: "pinned")
            object["notes"] = entries
            legacy = (try? JSONSerialization.data(withJSONObject: object))
                .flatMap { try? JSONDecoder().decode(NotesIndex.self, from: $0) }
        }
        suite.expect(legacy?.notes.first?.pinned == false && legacy?.notes.first?.text == "Keep",
                     "an index written before pinning existed still reads, with every note unpinned")
    }

    // MARK: - Disk

    private static func store(_ suite: TestSuite) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: directory) }

        var store = NotesStore(directoryURL: directory)
        let empty = try? store.loadIndex()
        suite.expect(empty == .empty && store.canSave, "a first launch starts with no notes and may save")

        let entry = note("Plan\nDetails")
        suite.expect(store.saveIndex(NotesIndex(notes: [entry], selectedID: entry.id)),
                     "the index is written")
        var reopened = NotesStore(directoryURL: directory)
        suite.expect((try? reopened.loadIndex()) == NotesIndex(notes: [entry], selectedID: entry.id),
                     "the index reads back as it was written")

        let body = NSMutableAttributedString(string: "Plan ", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
        body.append(NSAttributedString(string: "bold", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.black]))
        let pixel = NSImage(size: NSSize(width: 4, height: 4))
        pixel.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        pixel.unlockFocus()
        let png = pixel.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .png, properties: [:]) ?? Data()
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "pixel.png"
        body.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        suite.expect(reopened.saveBody(body, for: entry.id), "a body with formatting and an image is written")

        let read = reopened.loadBody(for: entry.id)
        var bold = false
        var colored = false
        var image: Data?
        if let read {
            let whole = NSRange(location: 0, length: read.length)
            read.enumerateAttribute(.font, in: whole) { value, _, _ in
                if let font = value as? NSFont, NSFontManager.shared.traits(of: font).contains(.boldFontMask) { bold = true }
            }
            read.enumerateAttribute(.foregroundColor, in: whole) { value, _, _ in if value != nil { colored = true } }
            read.enumerateAttribute(.attachment, in: whole) { value, _, _ in
                if let attachment = value as? NSTextAttachment { image = attachment.fileWrapper?.regularFileContents }
            }
        }
        suite.expect(read?.string.hasPrefix("Plan bold") == true && bold,
                     "text and bold formatting survive the round trip")
        suite.expect(image == png, "a pasted image is stored inside the note, byte for byte")
        suite.expect(!colored, "colors are left out of the file, so the note follows the panel's appearance")
        suite.expect(reopened.loadBody(for: UUID())?.length == 0, "a note never written yet reads as empty")

        if let url = reopened.bodyURL(for: entry.id) { try? Data("not rtfd".utf8).write(to: url) }
        suite.expect(reopened.loadBody(for: entry.id) == nil,
                     "an unreadable body is reported rather than read as empty")

        try? Data("{broken".utf8).write(to: directory.appendingPathComponent("Notes.json"))
        var broken = NotesStore(directoryURL: directory)
        suite.expect((try? broken.loadIndex()) == nil && !broken.canSave
                     && !broken.saveIndex(.empty) && !broken.saveBody(NSAttributedString(), for: entry.id),
                     "an unreadable index switches saving off, so nothing is written over it")
        suite.expect((try? Data(contentsOf: directory.appendingPathComponent("Notes.json"))) == Data("{broken".utf8),
                     "the unreadable index is left exactly as it was")
    }

    // MARK: - In the notch

    private static func placement(_ suite: TestSuite) {
        suite.expect(NotchModule.notes.isAvailable(in: UserDefaults(suiteName: "com.altf4.tests.notes")!),
                     "notes are available wherever the island is")
        let roomy = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1470, height: 956), safeAreaTop: 32, cameraWidth: 180)
        suite.expect(roomy.expandedSize(module: .notes).width >= 720
                     && roomy.expandedSize(module: .controls).width == roomy.expandedWidth,
                     "notes get room for two columns while other modules keep their width")
        suite.expect(roomy.expandedSize(module: .notes, detail: true).width == roomy.expandedWidth,
                     "a detail page over notes uses the ordinary width")
        let small = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 800, height: 560), safeAreaTop: 0, cameraWidth: 0)
        let size = small.expandedSize(module: .notes)
        suite.expect(size.width <= 800 - 24 - NotchQuickAccessLayout.gutter * 2 && size.height <= 560 - 48,
                     "a small screen narrows notes instead of pushing them off the display")
    }
}
