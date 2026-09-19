// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import AppKit
import Carbon.HIToolbox
import SwiftUI

enum NoteTextStyle: CaseIterable {
    case title, heading, body

    var font: NSFont {
        switch self {
        case .title: return .systemFont(ofSize: 22, weight: .bold)
        case .heading: return .systemFont(ofSize: 17, weight: .bold)
        case .body: return .systemFont(ofSize: 14)
        }
    }
}

/// Where the formatting controls send their commands. The editor registers
/// its text view here, so buttons outside it reach the note being written.
final class NotesEditorController {
    fileprivate weak var textView: NotesTextView?

    func toggle(_ trait: NSFontTraitMask) { textView?.toggle(trait) }
    func toggleUnderline() { textView?.toggleLine(.underlineStyle) }
    func toggleStrikethrough() { textView?.toggleLine(.strikethroughStyle) }
    func apply(_ style: NoteTextStyle) { textView?.apply(style) }
    func toggleList(_ kind: NoteListKind) { textView?.toggleList(kind) }
}

struct NotesEditor: NSViewRepresentable {
    let noteID: UUID
    let editable: Bool
    let focusRequest: Int
    let controller: NotesEditorController
    let load: (UUID) -> NSAttributedString
    let changed: (UUID, NSAttributedString) -> Void
    let focused: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = WidthTrackingScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // TextKit 1: its attachment cells are what scale a pasted image to
        // the column, and the list and checkbox edits below address the
        // storage by character, which it keeps simple.
        let textView = NotesTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.typingAttributes = NotesTextView.bodyAttributes
        textView.delegate = context.coordinator
        textView.onFocus = focused
        scroll.documentView = textView
        controller.textView = textView
        context.coordinator.load(noteID, into: textView, using: load)
        // A note that is still empty is one about to be written, so it takes
        // the caret as soon as it appears.
        context.coordinator.focusRequest = textView.string.isEmpty ? focusRequest &- 1 : focusRequest
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NotesTextView else { return }
        controller.textView = textView
        textView.onFocus = focused
        context.coordinator.changed = changed
        if context.coordinator.noteID != noteID {
            context.coordinator.load(noteID, into: textView, using: load)
        }
        textView.isEditable = editable
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteID: UUID?
        var focusRequest = 0
        var changed: (UUID, NSAttributedString) -> Void
        private var loading = false

        init(changed: @escaping (UUID, NSAttributedString) -> Void) {
            self.changed = changed
        }

        func load(_ id: UUID, into textView: NotesTextView, using load: (UUID) -> NSAttributedString) {
            loading = true
            noteID = id
            textView.textStorage?.setAttributedString(load(id))
            textView.adoptNoteColors()
            textView.fitAttachments()
            textView.typingAttributes = NotesTextView.bodyAttributes
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(.zero)
            // Undo recorded against the previous note's text would replay
            // into this one.
            textView.undoManager?.removeAllActions()
            loading = false
        }

        func textDidChange(_ notification: Notification) {
            guard !loading, let noteID, let textView = notification.object as? NotesTextView else { return }
            textView.fitAttachments()
            changed(noteID, NSAttributedString(attributedString: textView.attributedString()))
        }
    }
}

/// Keeps the text view exactly as wide as the visible column, so text wraps
/// to it from the first layout instead of after a resize.
private final class WidthTrackingScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let documentView, documentView.frame.width != contentSize.width else { return }
        documentView.setFrameSize(NSSize(width: contentSize.width, height: documentView.frame.height))
    }
}

final class NotesTextView: NSTextView {
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: NoteTextStyle.body.font, .foregroundColor: NSColor.textColor]
    }

    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    /// The panel sits in a background app, where the menu bar's Edit and
    /// Format menus never see these keys, so the editor answers them itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch modifiers {
        case [.command]:
            switch key {
            case "b": toggle(.boldFontMask)
            case "i": toggle(.italicFontMask)
            case "u": toggleLine(.underlineStyle)
            case "c": copy(nil)
            case "x": cut(nil)
            case "v": paste(nil)
            case "a": selectAll(nil)
            case "z": undoManager?.undo()
            case "f":
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                performTextFinderAction(item)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        case [.command, .shift]:
            switch (key, Int(event.keyCode)) {
            case ("z", _): undoManager?.redo()
            case ("t", _): apply(.title)
            case ("h", _): apply(.heading)
            case ("b", _): apply(.body)
            case ("x", _): toggleLine(.strikethroughStyle)
            case ("l", _): toggleList(.checklist)
            case (_, kVK_ANSI_7): toggleList(.bullet)
            case (_, kVK_ANSI_9): toggleList(.numbered)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        case [.command, .shift, .option] where key == "v":
            pasteAsPlainText(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Pasting

    /// Rich text keeps its bold, italics, links and images but takes the
    /// note's typeface and color: the source's colors are often black, which
    /// vanishes on the panel. Web pages that offer only HTML are pasted as
    /// text, since reading HTML can fetch every image it links to.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if board.availableType(from: [.rtfd, .rtf]) != nil,
           let pasted = board.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString {
            insertText(Self.adapted(pasted), replacementRange: selectedRange())
        } else if board.availableType(from: [.html]) != nil, let plain = board.string(forType: .string) {
            insertText(plain, replacementRange: selectedRange())
        } else {
            super.paste(sender)
        }
        fitAttachments()
    }

    static func adapted(_ pasted: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: pasted)
        let whole = NSRange(location: 0, length: result.length)
        result.removeAttribute(.backgroundColor, range: whole)
        result.removeAttribute(.paragraphStyle, range: whole)
        result.addAttribute(.foregroundColor, value: NSColor.textColor, range: whole)
        let manager = NSFontManager.shared
        result.enumerateAttribute(.font, in: whole) { value, range, _ in
            let traits = (value as? NSFont).map { manager.traits(of: $0) } ?? []
            var font = NoteTextStyle.body.font
            if traits.contains(.boldFontMask) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }

    // MARK: Lists and checkboxes

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange()
        let paragraph = text.paragraphRange(for: NSRange(location: caret.location, length: 0))
        let line = text.substring(with: paragraph)
        switch NotesSupport.continuation(of: line) {
        case .none:
            super.insertNewline(sender)
        case .next(let marker):
            super.insertNewline(sender)
            replace(selectedRange(), with: marker)
        case .end(let length):
            replace(NSRange(location: paragraph.location, length: length), with: "")
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let caret = selectedRange()
        if string as? String == " ", caret.length == 0 {
            let text = self.string as NSString
            let paragraph = text.paragraphRange(for: NSRange(location: caret.location, length: 0))
            let typed = NSRange(location: paragraph.location, length: caret.location - paragraph.location)
            if let marker = NotesSupport.autoMarker(forPrefix: text.substring(with: typed)) {
                replace(typed, with: marker)
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// A click on a checklist's box ticks it rather than placing the caret.
    override func mouseDown(with event: NSEvent) {
        let text = string as NSString
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if index <= text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: index, length: 0))
            let line = text.substring(with: paragraph)
            if index - paragraph.location <= 1, let marker = NotesSupport.marker(of: line),
               let toggled = NotesSupport.toggledCheckbox(of: line) {
                replace(NSRange(location: paragraph.location, length: marker.length), with: toggled)
                return
            }
        }
        super.mouseDown(with: event)
    }

    func toggleList(_ kind: NoteListKind) {
        let text = string as NSString
        let block = text.paragraphRange(for: selectedRange())
        var paragraphs: [NSRange] = []
        var location = block.location
        repeat {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(paragraph)
            location = NSMaxRange(paragraph)
        } while location < NSMaxRange(block) && paragraphs.last?.length ?? 0 > 0
        let changes = NotesSupport.toggledMarkers(for: paragraphs.map { text.substring(with: $0) }, kind: kind)
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        // Last paragraph first, so the ranges before it stay where they were.
        for (paragraph, change) in zip(paragraphs, changes).reversed()
        where change.removing > 0 || !change.inserting.isEmpty {
            replace(NSRange(location: paragraph.location, length: change.removing), with: change.inserting)
        }
        undoManager?.endUndoGrouping()
    }

    // MARK: Formatting

    func toggle(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let range = selectedRange()
        func flipped(_ font: NSFont, off: Bool) -> NSFont {
            off ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
        guard range.length > 0, let storage = textStorage else {
            let font = typingAttributes[.font] as? NSFont ?? NoteTextStyle.body.font
            typingAttributes[.font] = flipped(font, off: manager.traits(of: font).contains(trait))
            return
        }
        var everywhere = true
        storage.enumerateAttribute(.font, in: range) { value, _, stop in
            if !manager.traits(of: value as? NSFont ?? NoteTextStyle.body.font).contains(trait) {
                everywhere = false
                stop.pointee = true
            }
        }
        edit(range) {
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                storage.addAttribute(.font, value: flipped(value as? NSFont ?? NoteTextStyle.body.font, off: everywhere),
                                     range: run)
            }
        }
    }

    func toggleLine(_ key: NSAttributedString.Key) {
        let range = selectedRange()
        let line = NSUnderlineStyle.single.rawValue
        guard range.length > 0, let storage = textStorage else {
            typingAttributes[key] = (typingAttributes[key] as? Int ?? 0) == 0 ? line : nil
            return
        }
        var everywhere = true
        storage.enumerateAttribute(key, in: range) { value, _, stop in
            if (value as? Int ?? 0) == 0 {
                everywhere = false
                stop.pointee = true
            }
        }
        edit(range) {
            if everywhere { storage.removeAttribute(key, range: range) }
            else { storage.addAttribute(key, value: line, range: range) }
        }
    }

    func apply(_ style: NoteTextStyle) {
        let paragraphs = (string as NSString).paragraphRange(for: selectedRange())
        typingAttributes[.font] = style.font
        guard paragraphs.length > 0, let storage = textStorage else { return }
        edit(paragraphs) { storage.addAttribute(.font, value: style.font, range: paragraphs) }
    }

    // MARK: Appearance

    /// Notes are stored without colors, so the text takes the panel's own.
    func adoptNoteColors() {
        guard let storage = textStorage else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                             range: NSRange(location: 0, length: storage.length))
    }

    /// Images are shown no wider than the column, like Notes does. Only the
    /// displayed size changes; the stored image keeps its own.
    func fitAttachments() {
        guard let storage = textStorage, let container = textContainer else { return }
        let limit = container.size.width - container.lineFragmentPadding * 2 - 4
        guard limit > 40 else { return }
        var resized: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let image = (attachment.attachmentCell as? NSTextAttachmentCell)?.image,
                  let natural = image.representations.first?.size,
                  natural.width > 0, natural.height > 0 else { return }
            let target = natural.width > limit
                ? NSSize(width: limit, height: (natural.height * limit / natural.width).rounded())
                : natural
            guard image.size != target else { return }
            image.size = target
            resized.append(range)
        }
        for range in resized { layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil) }
    }

    // MARK: Editing primitives

    /// Every change goes through the text view's own change bracket, which is
    /// what records it for undo and tells the delegate the note changed.
    private func replace(_ range: NSRange, with text: String) {
        guard let storage = textStorage else { return }
        let attributes = range.location < storage.length
            ? storage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        guard shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    private func edit(_ range: NSRange, _ change: () -> Void) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change()
        storage.endEditing()
        didChangeText()
    }
}
