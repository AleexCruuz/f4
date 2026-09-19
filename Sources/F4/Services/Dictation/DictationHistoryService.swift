// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import AppKit
import Combine
import Foundation

/// Every dictation delivered on this Mac, newest first. Main thread only, like
/// the dictation service that feeds it.
final class DictationHistoryService: ObservableObject {
    static let shared = DictationHistoryService()

    @Published private(set) var records: [DictationRecord] = []
    private var store: DictationHistoryStore

    private init() {
        store = DictationHistoryStore(fileURL: DictationHistoryStore.defaultURL)
        records = store.load()
    }

    func record(_ text: String, duration: TimeInterval, appName: String?) {
        let record = DictationRecord(id: UUID(), text: text, date: Date(), duration: duration, appName: appName)
        records = DictationHistory.inserting(record, into: records)
        store.save(records)
    }

    func remove(_ record: DictationRecord) {
        records.removeAll { $0.id == record.id }
        store.save(records)
    }

    func updateText(of id: UUID, to text: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var updated = records
        updated[index].text = text
        records = DictationHistory.sanitized(updated)
        store.save(records)
    }

    func copy(_ record: DictationRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.text, forType: .string)
    }
}
