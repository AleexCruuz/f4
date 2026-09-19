// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import AppKit

/// The notes directory: an index of every note and one RTFD file per body,
/// so images pasted into a note travel inside it. A failed read never
/// authorizes a write that would replace what could not be read.
struct NotesStore {
    let directoryURL: URL?
    private(set) var canSave = false

    init(directoryURL: URL?) {
        self.directoryURL = directoryURL
    }

    private var indexURL: URL? { directoryURL?.appendingPathComponent("Notes.json") }

    func bodyURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).rtfd")
    }

    /// A missing index is a first launch. Anything else that fails leaves
    /// saving switched off, so the unreadable file stays as it is.
    mutating func loadIndex() throws -> NotesIndex {
        canSave = false
        guard let indexURL else { throw CocoaError(.fileReadUnknown) }
        let index: NotesIndex
        do {
            index = try JSONDecoder().decode(NotesIndex.self, from: Data(contentsOf: indexURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            index = .empty
        }
        canSave = true
        return index.sanitized()
    }

    @discardableResult
    func saveIndex(_ index: NotesIndex) -> Bool {
        guard canSave, let directoryURL, let indexURL,
              let data = try? JSONEncoder().encode(index) else { return false }
        return PrivateFileStore.createDirectory(at: directoryURL) && PrivateFileStore.write(data, to: indexURL)
    }

    /// Nil when the file is there and will not read. A note that was never
    /// written yet reads as empty.
    func loadBody(for id: UUID) -> NSAttributedString? {
        guard let url = bodyURL(for: id) else { return nil }
        do {
            return Self.deserialized(try Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return NSAttributedString()
        } catch {
            return nil
        }
    }

    @discardableResult
    func saveBody(_ body: NSAttributedString, for id: UUID) -> Bool {
        guard canSave, let directoryURL, let url = bodyURL(for: id),
              let data = Self.serialized(body) else { return false }
        return PrivateFileStore.createDirectory(at: directoryURL) && PrivateFileStore.write(data, to: url)
    }

    func removeBody(for id: UUID) {
        guard canSave, let url = bodyURL(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Colors are left out of the file. The note is drawn in whatever the
    /// panel's appearance calls text, and a color saved from one appearance
    /// is unreadable in the other.
    static func serialized(_ body: NSAttributedString) -> Data? {
        let neutral = NSMutableAttributedString(attributedString: body)
        let whole = NSRange(location: 0, length: neutral.length)
        neutral.removeAttribute(.foregroundColor, range: whole)
        neutral.removeAttribute(.backgroundColor, range: whole)
        return neutral.rtfd(from: whole, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    static func deserialized(_ data: Data) -> NSAttributedString? {
        NSAttributedString(rtfd: data, documentAttributes: nil)
    }
}
