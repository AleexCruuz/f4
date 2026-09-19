// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import Foundation

/// One finished dictation, with the text exactly as it was delivered.
struct DictationRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    let date: Date
    /// Seconds the microphone was open, from the press to the release.
    let duration: TimeInterval
    /// The app in front when the dictation started.
    let appName: String?
}

enum DictationHistory {
    /// Old dictations fall off the end instead of the file growing forever.
    static let limit = 500
    static let textLimit = 20_000
    static let maximumDuration: TimeInterval = 3_600

    /// Words spoken while a password field holds the keyboard may be the
    /// password, so they never reach the file.
    static func keeps(_ delivery: DictationDelivery) -> Bool {
        delivery != .copiedSecureInput
    }

    static func inserting(_ record: DictationRecord, into records: [DictationRecord]) -> [DictationRecord] {
        sanitized([record] + records)
    }

    /// Whatever the file held, reduced to what the page can show: no blank
    /// text, no repeated ids, a real number of seconds, newest first.
    static func sanitized(_ records: [DictationRecord]) -> [DictationRecord] {
        var ids = Set<UUID>()
        let clean = records.compactMap { record -> DictationRecord? in
            let text = String(record.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textLimit))
            guard !text.isEmpty, record.date.timeIntervalSinceReferenceDate.isFinite,
                  ids.insert(record.id).inserted else { return nil }
            let duration = record.duration.isFinite ? min(maximumDuration, max(0, record.duration)) : 0
            let app = record.appName.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
            return DictationRecord(id: record.id, text: text, date: record.date, duration: duration,
                                   appName: app?.isEmpty == false ? app : nil)
        }
        let ordered = clean.enumerated().sorted { lhs, rhs in
            lhs.element.date != rhs.element.date ? lhs.element.date > rhs.element.date : lhs.offset < rhs.offset
        }
        return ordered.prefix(limit).map(\.element)
    }

    static func filtered(_ records: [DictationRecord], matching query: String) -> [DictationRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return records }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return records.filter {
            $0.text.range(of: needle, options: options) != nil
                || $0.appName?.range(of: needle, options: options) != nil
        }
    }

    /// "0:07", "1:05", "1:02:03". Anything spoken reads as at least a second.
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite && seconds > 0 ? max(1, Int(seconds.rounded())) : 0
        let hours = total / 3_600, minutes = total % 3_600 / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }

    struct Day: Equatable, Identifiable {
        let start: Date
        let records: [DictationRecord]
        var id: Date { start }
        var duration: TimeInterval { records.reduce(0) { $0 + $1.duration } }
    }

    /// Runs of records spoken on the same calendar day, in the order given.
    static func days(_ records: [DictationRecord], calendar: Calendar) -> [Day] {
        var days: [Day] = []
        for record in records {
            let start = calendar.startOfDay(for: record.date)
            if let last = days.last, last.start == start {
                days[days.count - 1] = Day(start: start, records: last.records + [record])
            } else {
                days.append(Day(start: start, records: [record]))
            }
        }
        return days
    }
}

/// `History.json` in the app's private container. A file that is there and
/// will not read switches saving off, so it is never replaced by an empty list.
struct DictationHistoryStore {
    let fileURL: URL?
    private(set) var canSave = false

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    static var defaultURL: URL? {
        PrivateFileStore.containerURL?
            .appendingPathComponent("Dictation", isDirectory: true)
            .appendingPathComponent("History.json")
    }

    private struct File: Codable {
        var version = 1
        var records: [DictationRecord]
    }

    mutating func load() -> [DictationRecord] {
        canSave = false
        guard let fileURL else { return [] }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL))
            guard file.version == 1 else { return [] }
            canSave = true
            return DictationHistory.sanitized(file.records)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            canSave = true
            return []
        } catch {
            return []
        }
    }

    @discardableResult
    func save(_ records: [DictationRecord], container: URL? = PrivateFileStore.containerURL) -> Bool {
        guard canSave, let fileURL,
              let data = try? JSONEncoder().encode(File(records: records)) else { return false }
        return PrivateFileStore.createDirectory(at: fileURL.deletingLastPathComponent(), container: container)
            && PrivateFileStore.write(data, to: fileURL)
    }
}
