// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CoreGraphics

enum NotchModule: String, CaseIterable, Identifiable {
    case controls, mixer, music, clipboard, captures, files, system, tools, calendar, notifications, timer, camera, downloads, notes
    case dictation
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .controls: return "slider.horizontal.3"
        case .mixer: return "slider.vertical.3"
        case .music: return "music.note"
        case .timer: return "timer"
        case .camera: return "web.camera"
        case .downloads: return "arrow.down.circle"
        case .notes: return "note.text"
        case .dictation: return "mic"
        case .notifications: return "bell"
        case .calendar: return "calendar"
        case .clipboard: return "doc.on.clipboard"
        case .captures: return "camera.viewfinder"
        case .files: return "tray.full"
        case .system: return "gauge.with.dots.needle.50percent"
        case .tools: return "square.grid.2x2"
        }
    }

    /// Stable across ordering and languages; every destination has a direct key.
    var shortcutKey: String {
        switch self {
        case .controls: return "c"
        case .mixer: return "v"
        case .music: return "m"
        case .clipboard: return "b"
        case .captures: return "s"
        case .files: return "f"
        case .system: return "i"
        case .tools: return "t"
        case .calendar: return "a"
        case .notifications: return "n"
        case .timer: return "r"
        case .camera: return "w"
        case .downloads: return "d"
        case .notes: return "o"
        case .dictation: return "h"
        }
    }

    func isAvailable(in defaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .controls, .music, .notes: return true
        case .timer: return AppFeature.notchTimer.isAvailable(in: defaults)
        case .camera: return AppFeature.cameraPreview.isAvailable(in: defaults)
        case .downloads: return AppFeature.notchDownloads.isAvailable(in: defaults)
        case .notifications: return AppFeature.notchNotifications.isAvailable(in: defaults)
        case .calendar: return AppFeature.notchCalendar.isAvailable(in: defaults)
        case .mixer: return AppFeature.mixer.isAvailable(in: defaults)
        case .tools: return AppFeature.quickLauncher.isAvailable(in: defaults)
        case .clipboard: return AppFeature.clipboardHistory.isAvailable(in: defaults)
        case .captures:
            return AppFeature.screenshot.isAvailable(in: defaults)
                || AppFeature.screenRecorder.isAvailable(in: defaults)
                || AppFeature.screenOCR.isAvailable(in: defaults)
                || AppFeature.colorPicker.isAvailable(in: defaults)
        case .files: return AppFeature.shelf.isAvailable(in: defaults)
        case .dictation: return AppFeature.dictation.isAvailable(in: defaults)
        case .system:
            return [.monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork,
                    .monitorDisk, .monitorPower].contains { (feature: AppFeature) in
                feature.isAvailable(in: defaults)
            }
        }
    }
}

enum NotchDisplay: String, CaseIterable {
    case automatic, builtIn, main
}

enum NotchSize: String, CaseIterable {
    case compact, spacious, custom

    static let widthRange = 360.0...600.0
    static let heightRange = 400.0...640.0
    static let defaultWidth = 440.0
    static let defaultHeight = 480.0

    static func clamped(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    /// Width a preset asks for; a custom size keeps the one it stores.
    var presetWidth: CGFloat? {
        switch self {
        case .compact: return 480
        case .spacious: return 880
        case .custom: return nil
        }
    }
}

/// Shared measurements keep the window's content budget and its SwiftUI
/// layout in agreement, including small screens and custom sizes.
enum NotchLayout {
    static let horizontalInset: CGFloat = 28
    static let headerHeight: CGFloat = 36
    static let navigationHeight: CGFloat = 36
    static let spacing: CGFloat = 18
    static let bottomInset: CGFloat = 22
    static let controlHeight: CGFloat = 94
    static let musicControlHeight: CGFloat = 112
    static let shortcutHeight: CGFloat = 74
    static let actionHeight: CGFloat = 52
    static let actionSpacing: CGFloat = 8
    static let sectionTileHeight: CGFloat = 64
    /// Height of a Home card row without the music player in it.
    static let homeCardHeight: CGFloat = 58
    /// A panoramic Home's single row of cards, tall enough for a graph.
    static let panoramicCardHeight: CGFloat = 136
    /// Icon-only module tiles, all on one row under a panoramic Home's cards.
    static let dockTileHeight: CGFloat = 52
    static let sectionSpacing: CGFloat = 8
    static let sectionSearchHeight: CGFloat = 36
    static let sectionResultHeight: CGFloat = 52
    static var chromeHeight: CGFloat { headerHeight + spacing + bottomInset }
    /// Breathing room every compact strip keeps from its silhouette.
    static let compactEdgeGap: CGFloat = 5
    /// Bottom corner `NotchShape` draws for a surface of this height.
    ///
    /// A resting silhouette is as tall as the cutout, and the cutout's own
    /// corners are about a third of its height — `height / 2` turned it into a
    /// pill, which reads as a different shape than the hole it sits in.
    static func surfaceRadius(height: CGFloat) -> CGFloat { min(28, height * 0.34) }
}

/// The live cards Home leads with. A card is there only while its module is
/// installed, and each row pairs two cards that fit side by side.
enum NotchHomeCard: CaseIterable {
    case music, system, calendar, timer

    var module: NotchModule {
        switch self {
        case .music: return .music
        case .system: return .system
        case .calendar: return .calendar
        case .timer: return .timer
        }
    }

    static func rows(for modules: [NotchModule], panoramic: Bool) -> [[NotchHomeCard]] {
        (panoramic ? [allCases] : [[NotchHomeCard.music, .system], [.calendar, .timer]])
            .map { row in row.filter { modules.contains($0.module) } }
            .filter { !$0.isEmpty }
    }

    static func rowHeight(_ row: [NotchHomeCard], panoramic: Bool) -> CGFloat {
        if panoramic { return NotchLayout.panoramicCardHeight }
        return row.contains(.music) ? NotchLayout.musicControlHeight : NotchLayout.homeCardHeight
    }
}

enum NotchIdleContent: String, CaseIterable {
    case none, battery, music
}

/// Resizing can send hover exits and entries without any pointer movement.
struct NotchHoverState {
    private(set) var suppressed = false

    mutating func close(pointerInside: Bool) { suppressed = pointerInside }
    mutating func open() { suppressed = false }
    mutating func update(pointerInside: Bool) {
        if !pointerInside { suppressed = false }
    }
}

enum NotchCompactActivity: Equatable {
    case timer, downloads, music

    var module: NotchModule {
        switch self {
        case .timer: return .timer
        case .downloads: return .downloads
        case .music: return .music
        }
    }
}

enum NotchControlItem: String, CaseIterable, Identifiable {
    case volume, brightness, music, mixer, keepAwake, timer, calendar, microphone, screenshot, recording, speedTest, commandBar
    static let defaultHidden = ""
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .volume: return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .keepAwake: return "cup.and.saucer"
        case .microphone: return "mic.fill"
        case .screenshot: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .speedTest: return "speedometer"
        case .mixer: return "slider.vertical.3"
        case .commandBar: return "command"
        case .music: return NotchModule.music.symbol
        case .timer: return NotchModule.timer.symbol
        case .calendar: return NotchModule.calendar.symbol
        }
    }

    func isAvailable(in defaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .volume: return AppFeature.mixer.isAvailable(in: defaults)
        case .mixer: return AppFeature.mixer.isAvailable(in: defaults) && NotchSupport.modules(in: defaults).contains(.mixer)
        case .brightness: return AppFeature.brightness.isAvailable(in: defaults)
        case .keepAwake: return AppFeature.keepAwake.isAvailable(in: defaults)
        case .microphone: return AppFeature.micMute.isAvailable(in: defaults)
        case .screenshot: return AppFeature.screenshot.isAvailable(in: defaults)
        case .recording: return AppFeature.screenRecorder.isAvailable(in: defaults)
        case .speedTest: return AppFeature.monitorNetwork.isAvailable(in: defaults) && NotchSupport.modules(in: defaults).contains(.system)
        case .commandBar: return AppFeature.commandBar.isAvailable(in: defaults)
        case .music: return NotchSupport.modules(in: defaults).contains(.music)
        case .timer: return NotchSupport.modules(in: defaults).contains(.timer)
        case .calendar: return NotchSupport.modules(in: defaults).contains(.calendar)
        }
    }
}

enum NotchQuickAccessSide: String, CaseIterable, Codable {
    case left, right, bottom
}

enum NotchQuickAction: Hashable, Identifiable {
    case explore, settings, pin, module(NotchModule), control(NotchControlItem)

    var id: String {
        switch self {
        case .explore: return "explore"
        case .settings: return "settings"
        case .pin: return "pin"
        case .module(let module): return module.rawValue
        case .control(let item): return "control." + item.rawValue
        }
    }

    init?(id: String) {
        switch id {
        case "explore": self = .explore
        case "settings": self = .settings
        case "pin": self = .pin
        default:
            if id.hasPrefix("control."), let item = NotchControlItem(rawValue: String(id.dropFirst(8))) {
                self = .control(item)
            } else if let module = NotchModule(rawValue: id) { self = .module(module) }
            else { return nil }
        }
    }

    static var optionalActions: [Self] {
        [.explore, .settings, .pin] + NotchModule.allCases.map(Self.module)
            + NotchControlItem.allCases.filter { $0 != .volume && $0 != .brightness }.map(Self.control)
    }

    func isAvailable(in defaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .module(let module): return NotchSupport.modules(in: defaults).contains(module)
        case .control(let item): return item.isAvailable(in: defaults)
        default: return true
        }
    }
}

struct NotchQuickButton: Codable, Equatable, Identifiable {
    var id: UUID
    var actionID: String
    var side: NotchQuickAccessSide
    var label: String

    init(id: UUID = UUID(), action: NotchQuickAction, side: NotchQuickAccessSide, label: String = "") {
        self.id = id
        actionID = action.id
        self.side = side
        self.label = label
    }

    var action: NotchQuickAction? { NotchQuickAction(id: actionID) }
}

struct NotchQuickAccessConfiguration: Equatable, Codable {
    var buttons: [NotchQuickButton]
    private var version = 1
    /// One column has to hold every button now that the default keeps them all
    /// on one side. The editor still allows the other sides.
    static let maximumPerSide = 5
    /// All on the left. Buttons split across three edges gave the panel no
    /// resting place for the eye — you had to look in three directions to find
    /// out what was on offer, and the side a button sat on carried no meaning.
    static let initial = Self(buttons: [
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, action: .explore, side: .left),
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, action: .module(.timer), side: .left),
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, action: .settings, side: .left),
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, action: .module(.mixer), side: .left),
        NotchQuickButton(id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!, action: .module(.dictation), side: .left),
    ])
    var actions: [NotchQuickAction] { buttons.compactMap(\.action) }
    var hasBottom: Bool { buttons.contains { $0.side == .bottom } }
    var longestColumn: Int {
        [NotchQuickAccessSide.left, .right].map { side in buttons.filter { $0.side == side }.count }.max() ?? 0
    }

    init(buttons: [NotchQuickButton]) { self.buttons = buttons }

    /// Stable IDs allow the previous single-side preferences to remain live
    /// until the first deliberate edit saves the new layout.
    init(side: NotchQuickAccessSide, actions: [NotchQuickAction]) {
        buttons = actions.enumerated().map { index, action in
            NotchQuickButton(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                             action: action, side: side)
        }
    }

    func sanitized() -> Self {
        var ids = Set<UUID>()
        var counts: [NotchQuickAccessSide: Int] = [:]
        let safe = buttons.prefix(64).compactMap { button -> NotchQuickButton? in
            guard button.action != nil, ids.insert(button.id).inserted,
                  counts[button.side, default: 0] < Self.maximumPerSide else { return nil }
            counts[button.side, default: 0] += 1
            var result = button
            result.label = String(button.label.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            return result
        }
        return Self(buttons: safe)
    }

    var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(sanitized())) ?? Data()
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: DefaultsKey.notchQuickAccessLayout), !data.isEmpty, data.count <= 32_768,
           let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 {
            return value.sanitized()
        }
        // These retired keys have no registration defaults, so even an empty
        // saved value is an explicit legacy choice rather than a fresh install.
        let legacyKeys = [DefaultsKey.notchQuickAccessSide, DefaultsKey.notchQuickAccessSecond, DefaultsKey.notchQuickAccessThird]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return .initial }
        let side = NotchQuickAccessSide(rawValue: defaults.string(forKey: DefaultsKey.notchQuickAccessSide) ?? "") ?? .left
        var actions: [NotchQuickAction] = [.explore]
        for key in [DefaultsKey.notchQuickAccessSecond, DefaultsKey.notchQuickAccessThird] {
            let id = defaults.string(forKey: key) ?? (key == DefaultsKey.notchQuickAccessSecond ? NotchQuickAction.settings.id : "")
            guard let action = NotchQuickAction(id: id),
                  !actions.contains(action) else { continue }
            actions.append(action)
        }
        return Self(side: side, actions: actions)
    }

    static func current(in defaults: UserDefaults = .standard) -> Self {
        var configuration = stored(in: defaults)
        configuration.buttons.removeAll { $0.action?.isAvailable(in: defaults) != true }
        return configuration
    }

    mutating func move(_ id: UUID, to side: NotchQuickAccessSide, before target: UUID? = nil) {
        guard let index = buttons.firstIndex(where: { $0.id == id }),
              buttons[index].side == side || buttons.filter({ $0.side == side }).count < Self.maximumPerSide else { return }
        var item = buttons.remove(at: index)
        item.side = side
        let destination = target.flatMap { target in buttons.firstIndex(where: { $0.id == target && $0.side == side }) }
        buttons.insert(item, at: destination ?? buttons.endIndex)
    }
}

struct NotchQuickAccessPlacement: Equatable, Identifiable {
    let button: NotchQuickButton
    let index: Int
    let edge: CGFloat
    let top: CGFloat
    var id: UUID { button.id }
    var side: NotchQuickAccessSide { button.side }
    func center(progress: CGFloat) -> CGPoint {
        NotchQuickAccessLayout.center(index: index, progress: progress, edge: edge, top: top, side: side)
    }
}

/// All coordinates are in the flipped presentation container, including the
/// transparent space reserved beside the black notch.
enum NotchQuickAccessLayout {
    static let diameter: CGFloat = 44
    static let gap: CGFloat = 12
    static let gutter: CGFloat = 72
    static let rowSpacing: CGFloat = 54
    static let withdrawalDuration = 0.16
    static let hoverMargin: CGFloat = 16
    static let hoverExitDelay = 0.04

    static func center(index: Int, progress: CGFloat, edge: CGFloat, top: CGFloat,
                       side: NotchQuickAccessSide) -> CGPoint {
        let phase = progress.isFinite ? min(1.1, max(0, progress)) : 0
        let offset = -14 + phase * (14 + gap + diameter / 2)
        if side == .bottom { return CGPoint(x: top + CGFloat(index) * rowSpacing, y: edge + offset) }
        return CGPoint(x: edge + (side == .left ? -offset : offset), y: top + CGFloat(index) * rowSpacing)
    }

    /// Hover is a continuous corridor, including the gaps and a forgiving rim.
    /// Clicks still use the exact circles below.
    static func hoverRect(count: Int, edge: CGFloat, top: CGFloat,
                          side: NotchQuickAccessSide) -> CGRect {
        guard count > 0 else { return .null }
        let first = center(index: 0, progress: 1, edge: edge, top: top, side: side)
        let last = center(index: count - 1, progress: 1, edge: edge, top: top, side: side)
        let radius = diameter / 2
        if side == .bottom {
            return CGRect(x: first.x - radius, y: edge, width: last.x - first.x + diameter,
                          height: first.y + radius - edge).insetBy(dx: -hoverMargin, dy: -hoverMargin)
        }
        return CGRect(x: min(first.x - radius, edge), y: first.y - radius,
                      width: max(first.x + radius, edge) - min(first.x - radius, edge),
                      height: last.y - first.y + diameter)
            .insetBy(dx: -hoverMargin, dy: -hoverMargin)
    }

    static func placements(_ configuration: NotchQuickAccessConfiguration, body: CGRect, headerTop: CGFloat) -> [NotchQuickAccessPlacement] {
        var indices: [NotchQuickAccessSide: Int] = [:]
        return configuration.buttons.map { button in
            let index = indices[button.side, default: 0]
            indices[button.side] = index + 1
            let count = configuration.buttons.filter { $0.side == button.side }.count
            let edge = button.side == .bottom ? body.maxY : button.side == .left ? body.minX : body.maxX
            let top = button.side == .bottom ? body.midX - CGFloat(count - 1) * rowSpacing / 2 : headerTop
            return NotchQuickAccessPlacement(button: button, index: index, edge: edge, top: top)
        }
    }

    static func hitTest(_ point: CGPoint, count: Int, edge: CGFloat, top: CGFloat,
                        side: NotchQuickAccessSide) -> Bool {
        (0..<max(0, count)).contains { index in
            let center = center(index: index, progress: 1, edge: edge, top: top, side: side)
            return hypot(point.x - center.x, point.y - center.y) <= diameter / 2
        }
    }

    /// Transparent height the window keeps below the notch's body. A side
    /// column hangs from the header, so on a page shorter than the column the
    /// lower buttons and their hover rim would otherwise fall outside the window.
    static func reservedBottom(_ configuration: NotchQuickAccessConfiguration?, height: CGFloat,
                               headerTop: CGFloat) -> CGFloat {
        guard let configuration else { return 0 }
        let row: CGFloat = configuration.hasBottom ? gutter : 0
        let column = configuration.longestColumn
        guard column > 0 else { return row }
        let columnBottom = headerTop + CGFloat(column - 1) * rowSpacing + diameter / 2 + hoverMargin
        return max(row, ceil(columnBottom - height))
    }
}

enum NotchEvent: String, CaseIterable {
    case volume, brightness, battery, clipboard, capture, systemNotification, keyboardLight, timer, accessory, download
    case dictation

    var preferenceKey: String {
        switch self {
        case .timer: return DefaultsKey.notchTimerEnabled
        case .accessory: return DefaultsKey.notchAccessoriesEnabled
        case .download: return DefaultsKey.notchDownloadsEnabled
        case .systemNotification: return DefaultsKey.notchNotificationsEnabled
        case .keyboardLight: return DefaultsKey.notchKeyboardLight
        case .volume: return DefaultsKey.notchVolume
        case .brightness: return DefaultsKey.notchBrightness
        case .battery: return DefaultsKey.notchBattery
        case .clipboard: return DefaultsKey.notchClipboard
        case .capture: return DefaultsKey.notchCapture
        case .dictation: return DefaultsKey.dictationEnabled
        }
    }

    var priority: Int {
        switch self {
        // The only notice that stands for something still happening: a
        // volume key pressed mid-sentence must not hide that the mic is open.
        case .dictation: return 4
        case .volume, .brightness, .keyboardLight: return 3
        case .capture, .timer: return 2
        case .battery, .systemNotification, .accessory: return 1
        case .clipboard, .download: return 0
        }
    }

    var duration: TimeInterval {
        switch self {
        case .volume, .brightness, .keyboardLight: return 1.6
        case .systemNotification: return 3
        case .timer, .download: return 6
        case .battery, .accessory: return 4
        case .clipboard: return 2.5
        case .capture: return 12
        // Dismissed by the dictation itself; this only bounds a lost one.
        case .dictation: return 6 * 60
        }
    }
}

enum NotchSupport {
    static let toolColumns = 5
    static let defaultHoverDelay = 0.10
    static let hoverDelayRange = 0.10...1.0

    /// Animation timings, overridable at runtime so they can be tuned without a
    /// rebuild. Tuning a feel is a loop of change-a-number, look, change again,
    /// and a 25-second compile between each look breaks it: by the time the
    /// build lands you have lost what you were comparing against.
    ///
    ///     defaults write com.altf4.utils.dev notchRevealDuration -float 0.12
    ///
    /// then relaunch. Developer builds only — the shipped app always uses the
    /// constants here, so a stray default cannot change what users get.
    enum Timing {
        static let reveal: TimeInterval = 0.20
        static let moduleFade: TimeInterval = 0.10

        static func reveal(in defaults: UserDefaults = .standard) -> TimeInterval {
            resolve(DefaultsKey.notchRevealDuration, fallback: reveal, in: defaults)
        }

        static func moduleFade(in defaults: UserDefaults = .standard) -> TimeInterval {
            resolve(DefaultsKey.notchModuleFadeDuration, fallback: moduleFade, in: defaults)
        }

        /// Zero is a legitimate "no animation", so it is the ABSENCE of the key
        /// that falls back, not a falsy value.
        private static func resolve(_ key: String,
                                    fallback: TimeInterval,
                                    in defaults: UserDefaults) -> TimeInterval {
            guard AppInfo.isDeveloperBuild, defaults.object(forKey: key) != nil else { return fallback }
            let value = defaults.double(forKey: key)
            return value.isFinite && (0...2).contains(value) ? value : fallback
        }
    }

    /// How long a closed panel still resumes the page it was left on.
    static let resumeWindow: TimeInterval = 30

    static func reopensAtHome(closedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let closedAt, closedAt.isFinite, now.isFinite else { return false }
        return now - closedAt > resumeWindow
    }

    static func sanitizedHoverDelay(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(hoverDelayRange.upperBound, max(hoverDelayRange.lowerBound, value)) : defaultHoverDelay
    }

    static func moduleShortcut(_ characters: String, modules: [NotchModule]) -> NotchModule? {
        modules.first { $0.shortcutKey == characters.lowercased() }
    }

    static func filteredModules(_ modules: [NotchModule], query: String,
                                title: (NotchModule) -> String) -> [NotchModule] {
        let terms = CommandBarSearch.normalized(query).split(separator: " ")
        guard !terms.isEmpty else { return modules }
        return modules.filter { module in
            let name = CommandBarSearch.normalized(title(module))
            return terms.allSatisfy { name.contains($0) }
        }
    }

    static func adjacentModule(to selected: NotchModule?, modules: [NotchModule], backwards: Bool) -> NotchModule? {
        guard !modules.isEmpty else { return nil }
        guard let selected, let index = modules.firstIndex(of: selected) else { return modules.first }
        return modules[(index + (backwards ? modules.count - 1 : 1)) % modules.count]
    }

    static func compactActivity(timer: Bool, downloads: Bool, music: Bool) -> NotchCompactActivity? {
        if timer { return .timer }
        if downloads { return .downloads }
        return music ? .music : nil
    }

    static func gestureIsOverHeader(expanded: Bool, peeking: Bool, fromTop: CGFloat, safeTop: CGFloat) -> Bool {
        (expanded || peeking) && (safeTop...safeTop + NotchLayout.headerHeight).contains(fromTop)
    }

    static func keepsPermissionSurface(requesting: Bool, resolvedAt: TimeInterval?, now: TimeInterval) -> Bool {
        if requesting { return true }
        guard let resolvedAt, now.isFinite, resolvedAt.isFinite else { return false }
        return (0..<1).contains(now - resolvedAt)
    }

    /// The notch has no switch of its own: it is how the app presents, so it
    /// is on for as long as the feature is installed.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        AppFeature.notch.isAvailable(in: defaults)
    }

    static func usesHapticFeedback(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchHapticFeedback)
    }

    static func modules(in defaults: UserDefaults = .standard) -> [NotchModule] {
        let hidden = Set((defaults.string(forKey: DefaultsKey.notchHiddenModules) ?? "")
            .split(separator: ",").map(String.init))
        let stored = (defaults.string(forKey: DefaultsKey.notchModuleOrder) ?? "")
            .split(separator: ",").compactMap { NotchModule(rawValue: String($0)) }
        var seen = Set<NotchModule>()
        return (stored + NotchModule.allCases).filter {
            seen.insert($0).inserted && !hidden.contains($0.rawValue) && $0.isAvailable(in: defaults)
                && ($0 != .timer || defaults.bool(forKey: DefaultsKey.notchTimerEnabled))
                && ($0 != .calendar || defaults.bool(forKey: DefaultsKey.notchCalendarEnabled))
                && ($0 != .notifications || defaults.bool(forKey: DefaultsKey.notchNotificationsEnabled))
        }
    }

    static func watchesMusicActivity(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && modules(in: defaults).contains(.music)
            && idleContent(in: defaults) != .none
            && (defaults.object(forKey: DefaultsKey.notchShowPlayingMusic) as? Bool ?? true)
    }

    static func showsMusicActivity(isPlaying: Bool, in defaults: UserDefaults = .standard) -> Bool {
        isPlaying && watchesMusicActivity(in: defaults)
    }

    static func showsInCaptures(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.notchShowInCaptures) as? Bool ?? true
    }

    static func idleContent(in defaults: UserDefaults = .standard) -> NotchIdleContent {
        let choice = NotchIdleContent(rawValue: defaults.string(forKey: DefaultsKey.notchIdleContent) ?? "") ?? .none
        if choice == .battery, !AppFeature.monitorPower.isAvailable(in: defaults) { return .none }
        if choice == .music, !modules(in: defaults).contains(.music) { return .none }
        return choice
    }

    static func visibleIdleContent(isPlaying: Bool, in defaults: UserDefaults = .standard) -> NotchIdleContent {
        let choice = idleContent(in: defaults)
        return choice == .music && !showsMusicActivity(isPlaying: isPlaying, in: defaults) ? .none : choice
    }

    static func controls(in defaults: UserDefaults = .standard) -> [NotchControlItem] {
        let hidden = Set((defaults.string(forKey: DefaultsKey.notchHiddenControls) ?? NotchControlItem.defaultHidden)
            .split(separator: ",").map(String.init))
        let stored = (defaults.string(forKey: DefaultsKey.notchControlOrder) ?? "")
            .split(separator: ",").compactMap { NotchControlItem(rawValue: String($0)) }
        var seen = Set<NotchControlItem>()
        return (stored + NotchControlItem.allCases).filter {
            seen.insert($0).inserted && !hidden.contains($0.rawValue) && $0.isAvailable(in: defaults)
        }
    }

    static func systemCardCount(hasBattery: Bool, in defaults: UserDefaults = .standard) -> Int {
        [.monitorCPU, .monitorGPU, .monitorMemory, .monitorDisk].filter {
            (feature: AppFeature) in feature.isAvailable(in: defaults)
        }.count + (AppFeature.monitorNetwork.isAvailable(in: defaults) ? 1 : 0)
            + (AppFeature.monitorPower.isAvailable(in: defaults) ? (hasBattery ? 2 : 1) : 0)
    }

    /// Direct openings are dismissed explicitly, never by the pointer's
    /// initial position at the menu bar or in the application being used.
    static func closesOnPointerExit(expanded: Bool, peeking: Bool, openedByHover: Bool) -> Bool {
        peeking || (expanded && openedByHover)
    }

    static func routes(_ event: NotchEvent, in defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(in: defaults), defaults.bool(forKey: event.preferenceKey) else { return false }
        switch event {
        case .timer: return NotchTimerSupport.isEnabled(in: defaults)
        case .accessory: return NotchAccessorySupport.isEnabled(in: defaults)
        case .download: return AppFeature.notchDownloads.isAvailable(in: defaults)
            && modules(in: defaults).contains(.downloads)
        case .systemNotification: return NotchNotificationSupport.isEnabled(in: defaults)
        case .keyboardLight: return AppFeature.brightness.isAvailable(in: defaults)
        case .volume: return AppFeature.mixer.isAvailable(in: defaults)
        case .brightness:
            return AppFeature.brightness.isAvailable(in: defaults)
                && defaults.bool(forKey: DefaultsKey.brightnessControlEnabled)
        case .battery: return AppFeature.monitorPower.isAvailable(in: defaults)
        case .clipboard:
            return modules(in: defaults).contains(.clipboard)
                && defaults.bool(forKey: DefaultsKey.clipboardHistoryEnabled)
        case .capture:
            return AppFeature.screenshot.isAvailable(in: defaults)
                && modules(in: defaults).contains(.captures)
        case .dictation: return AppFeature.dictation.isAvailable(in: defaults)
        }
    }

    static func routesClipboardWindow(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchClipboardWindow)
            && modules(in: defaults).contains(.clipboard)
    }

    static func routesShelf(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchShelf)
            && modules(in: defaults).contains(.files)
    }

    static func revealsShelfDrag(in defaults: UserDefaults = .standard) -> Bool {
        routesShelf(in: defaults) && defaults.bool(forKey: DefaultsKey.notchDragReveal)
    }

    static func routesCaptureControls(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchCaptureControls)
            && modules(in: defaults).contains(.captures)
    }

    static func routesQuickPanel(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchQuickPanel)
            && AppFeature.quickLauncher.isAvailable(in: defaults)
            && modules(in: defaults).contains(.tools)
    }

    static func shouldReplace(_ current: NotchEvent?, with incoming: NotchEvent) -> Bool {
        current == nil || incoming.priority >= current!.priority
    }

    static func volumeLevel(current: Double, direction: Int, fine: Bool) -> Double {
        guard current.isFinite else { return 0 }
        return min(1, max(0, current + Double(direction.signum()) / (fine ? 64 : 16)))
    }

    static func screenIndex(preference: NotchDisplay, builtIn: [Bool], notched: [Bool], main: Int) -> Int? {
        guard !builtIn.isEmpty, builtIn.count == notched.count else { return nil }
        let fallback = builtIn.indices.contains(main) ? main : 0
        switch preference {
        case .main: return fallback
        case .builtIn: return builtIn.firstIndex(of: true) ?? fallback
        case .automatic:
            return builtIn.indices.first { builtIn[$0] && notched[$0] }
                ?? notched.firstIndex(of: true) ?? fallback
        }
    }
}

/// A hidden menu bar retains only a measurement from the same display and mode.
/// Until that display has a visible bar, use the native fallback rather than
/// borrowing the application's main-menu height from another display.
struct NotchMenuBarMeasurements {
    private struct Reading {
        let size: CGSize
        let scale: CGFloat
        let height: CGFloat
    }
    private var readings: [UInt32: Reading] = [:]

    mutating func retainDisplays(_ ids: [UInt32]) {
        readings = readings.filter { ids.contains($0.key) }
    }

    mutating func height(displayID: UInt32, frame: CGRect, visibleTop: CGFloat,
                         scale: CGFloat, statusBarThickness: CGFloat) -> CGFloat {
        let range: ClosedRange<CGFloat> = 16...64
        let gap = frame.maxY - visibleTop
        let canRemember = displayID != 0 && scale.isFinite && scale > 0
        if let previous = readings[displayID], previous.size != frame.size || previous.scale != scale {
            readings[displayID] = nil
        }
        if gap.isFinite, range.contains(gap) {
            if canRemember { readings[displayID] = Reading(size: frame.size, scale: scale, height: gap) }
            return gap
        }
        if canRemember, let previous = readings[displayID] { return previous.height }
        return statusBarThickness.isFinite && range.contains(statusBarThickness) ? statusBarThickness : 24
    }
}

/// Screen coordinates stay in points, including displays to the left or above
/// the primary display. No model name or pixel density is assumed.
struct NotchGeometry: Equatable {
    let screen: CGRect
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat
    let isNotched: Bool
    let layout: NotchSize
    let customWidth: CGFloat
    let customHeight: CGFloat
    let menuBarHeight: CGFloat
    var compactSideRoom: CGFloat?
    var quickAccessBottomInset: CGFloat = 0
    private var allowsActivityFooter = true
    private var minimumCompactWidth: CGFloat = 0

    init(screen: CGRect, safeAreaTop: CGFloat, cameraWidth: CGFloat, layout: NotchSize = .compact,
         menuBarHeight: CGFloat = 24, compactSideRoom: CGFloat? = nil,
         customWidth: Double = NotchSize.defaultWidth, customHeight: Double = NotchSize.defaultHeight) {
        self.screen = screen
        self.layout = layout
        self.customWidth = NotchSize.clamped(customWidth, to: NotchSize.widthRange, fallback: NotchSize.defaultWidth)
        self.customHeight = NotchSize.clamped(customHeight, to: NotchSize.heightRange, fallback: NotchSize.defaultHeight)
        let barHeight = menuBarHeight.isFinite ? min(64, max(16, menuBarHeight)) : 24
        isNotched = safeAreaTop.isFinite && safeAreaTop > 0 && cameraWidth.isFinite && cameraWidth > 0
        self.cameraWidth = min(isNotched ? cameraWidth : 180 * barHeight / 32, screen.width * 0.7)
        cameraHeight = isNotched ? min(safeAreaTop, 64) : barHeight
        self.menuBarHeight = max(cameraHeight, barHeight)
        self.compactSideRoom = compactSideRoom
    }

    func hasSameMenuBar(as other: NotchGeometry) -> Bool {
        screen == other.screen && cameraWidth == other.cameraWidth
            && menuBarHeight == other.menuBarHeight && isNotched == other.isNotched
    }

    var safeContentTop: CGFloat { cameraHeight + 10 }
    func activationArea(in size: CGSize, hasHeader: Bool, compactActivity: Bool) -> CGRect {
        let width = compactActivity ? cameraWidth : size.width
        let height = hasHeader ? min(safeContentTop, size.height)
            : compactActivity && compactActivityUsesFooter ? compactActivityTopPadding : size.height
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }

    var restingWingWidth: CGFloat {
        let available = min(44, max(0, compactSideRoom ?? 0)).rounded(.down)
        return available >= 44 ? available : 0
    }
    /// On a notched Mac the resting shape is the notch itself, so it has to be
    /// the notch's height and not the menu bar's. Those differ — the bar is
    /// taller than the cutout — and the gap is visible the moment the panel
    /// settles: the silhouette closes to something taller than the hardware it
    /// is supposed to be hiding behind, which reads as the animation missing
    /// its mark rather than as a deliberate shape. Machines without a cutout
    /// keep the bar height, which is the only sensible resting height there.
    var collapsed: CGSize {
        CGSize(width: min(screen.width - 24, cameraWidth + restingWingWidth * 2),
               height: isNotched ? cameraHeight : menuBarHeight)
    }
    func restingSize(showsContent: Bool) -> CGSize {
        showsContent ? collapsed : CGSize(width: cameraWidth, height: cameraHeight)
    }
    /// Music remains one row high, with the physical camera between its wings.
    /// Insufficient menu space hides the wings instead of growing below the camera.
    var compactMusicGeometry: NotchGeometry {
        var compact = self
        let room = compactSideRoom ?? 0
        compact.compactSideRoom = room.isFinite && room >= 44 ? min(56, room) : 0
        compact.allowsActivityFooter = false
        return compact
    }
    var musicCameraGap: CGFloat { cameraWidth }
    var compactMusicLabelInset: CGFloat {
        let bottom = NotchLayout.surfaceRadius(height: compactActivityContentHeight)
        // Wings normally provide this room. When menus hide them, the center
        // text must also clear the silhouette's bottom corners.
        return max(4, bottom + 4 - compactActivityWingWidth)
    }
    func compactTimerGeometry(showsDownloads: Bool) -> NotchGeometry {
        var compact = self
        let room = compactSideRoom ?? 0
        let wing: CGFloat = showsDownloads ? 80 : 72
        compact.compactSideRoom = room.isFinite && room >= 72 ? min(wing, room) : 0
        // A wider simulated camera must not consume the timer's text budget.
        compact.minimumCompactWidth = cameraWidth + wing * 2
        // Menu changes, including full-screen transitions, must not push the
        // timer below the camera. Its expanded view remains available by click.
        compact.allowsActivityFooter = false
        return compact
    }
    var musicStrip: CGSize {
        let preferred = min(max(layout == .spacious ? 520 : 440, cameraWidth + 88, minimumCompactWidth), screen.width - 24)
        let measuredRoom = compactSideRoom ?? 0
        let room = measuredRoom.isFinite ? max(0, measuredRoom).rounded(.down) : 0
        let wings = min(max(0, preferred - cameraWidth), room * 2)
        return CGSize(width: cameraWidth + (wings >= 88 ? wings : 0), height: menuBarHeight)
    }
    var musicWingWidth: CGFloat { max(0, (musicStrip.width - musicCameraGap) / 2) }

    /// Only a physical camera may need a footer. A simulated cutout and all
    /// of its compact activity stay within the real menu bar's height.
    var compactActivityUsesFooter: Bool { isNotched && allowsActivityFooter && musicWingWidth < 44 }
    var compactActivityContentHeight: CGFloat { compactActivityUsesFooter ? 32 : menuBarHeight }
    var compactActivityTopPadding: CGFloat { compactActivityUsesFooter ? menuBarHeight : 0 }
    var compactActivityHorizontalPadding: CGFloat { compactActivityUsesFooter ? 4 : 0 }
    var compactActivityCameraGap: CGFloat { compactActivityUsesFooter ? 0 : musicCameraGap }
    var compactActivitySize: CGSize {
        compactActivityUsesFooter
            ? CGSize(width: cameraWidth, height: compactActivityTopPadding + compactActivityContentHeight)
            : musicStrip
    }
    var compactActivityWingWidth: CGFloat {
        max(0, (compactActivitySize.width - compactActivityCameraGap - compactActivityHorizontalPadding * 2) / 2)
    }
    /// Inset that keeps a vertically centred box of `boxHeight`, itself rounded
    /// by `radius`, an even `gap` away from the strip's silhouette.
    /// A strip is barely taller than its corners, so its lower half is one long
    /// arc: padding measured against the straight edge still leaves artwork and
    /// meters grazing the curve. Push the box in until its own corner keeps the
    /// same distance from the arc that its top keeps from the straight side.
    func compactActivityEdgeInset(boxHeight: CGFloat, radius: CGFloat,
                                  gap: CGFloat = NotchLayout.compactEdgeGap) -> CGFloat {
        let corner = min(NotchLayout.surfaceRadius(height: compactActivitySize.height),
                         compactActivitySize.width / 2)
        let flat = gap - compactActivityHorizontalPadding
        let below = (compactActivityContentHeight - boxHeight) / 2
        // Both corner centres, grown by the gap, decide the horizontal offset.
        let reach = corner - radius - gap
        let drop = corner - radius - below
        guard reach > 0, drop > 0 else { return max(0, flat) }
        let span = reach > drop ? (reach * reach - drop * drop).squareRoot() : 0
        return max(0, flat, corner - radius - span - compactActivityHorizontalPadding)
    }
    var notice: CGSize {
        noticeSize(wingWidth: 112)
    }
    var noticeCameraGap: CGFloat { cameraWidth }

    /// A footer hangs below the camera, under the menu bar row.
    func noticeSize(wingWidth: CGFloat, footerHeight: CGFloat = 0) -> CGSize {
        CGSize(width: min(screen.width - 24, noticeCameraGap + wingWidth * 2),
               height: menuBarHeight + max(0, footerHeight))
    }

    func noticeWingWidth(preferred: CGFloat) -> CGFloat {
        max(0, (noticeSize(wingWidth: preferred).width - noticeCameraGap) / 2)
    }
    var peek: CGSize {
        CGSize(width: min(screen.width - 24, max(cameraWidth + 110, 340)), height: safeContentTop + 52)
    }
    var expanded: CGSize { expandedSize(module: .controls) }
    var expandedWidth: CGFloat {
        let preferred = layout.presetWidth ?? customWidth
        return min(max(preferred, cameraWidth + 36), screen.width - 24 - NotchQuickAccessLayout.gutter * 2)
    }
    var usesCompactContent: Bool { expandedWidth < 480 }
    /// Wide enough to spread a page sideways instead of stacking it: Home's
    /// cards share one row and every grid gains a column.
    var isPanoramic: Bool { expandedWidth >= 800 }
    var controlColumns: Int { isPanoramic ? 3 : hasSideBySideLevels ? 2 : 1 }
    var systemColumns: Int { isPanoramic ? 4 : expandedWidth >= 440 ? 3 : 2 }
    var hasSideBySideLevels: Bool { expandedWidth >= 440 }

    func expandedSize(module: NotchModule, detail: Bool = false, controlRows: Int = 2,
                      sliderCount: Int = 2, controlsHaveMusic: Bool = false, musicHasContent: Bool = true, musicExtraHeight: CGFloat = 0,
                      fileMediaHeight: CGFloat? = nil, systemRows: Int = 3,
                      capturePreviewHeight: CGFloat? = nil,
                      timerHasSession: Bool = false, timerMode: NotchTimerMode = .timer) -> CGSize {
        if module == .camera, !detail { return mirrorSize }
        let contentHeight: CGFloat
        switch module {
        case .controls:
            let rows = max(0, controlRows)
            let sliders = min(2, max(0, sliderCount))
            let levelRows = hasSideBySideLevels ? min(1, sliders) : sliders
            let groups = levelRows + (rows > 0 ? 1 : 0) + (controlsHaveMusic ? 1 : 0)
            let controls = (controlsHaveMusic ? NotchLayout.musicControlHeight : 0)
                + CGFloat(levelRows) * NotchLayout.controlHeight + CGFloat(rows) * NotchLayout.actionHeight
                + CGFloat(max(0, rows - 1)) * NotchLayout.actionSpacing + CGFloat(max(0, groups - 1)) * 18
            contentHeight = NotchLayout.chromeHeight + (groups == 0 ? 160 : controls)
        case .mixer: contentHeight = 400
        case .music: contentHeight = NotchLayout.chromeHeight
                + (musicHasContent ? (usesCompactContent ? 226 : 216) + musicExtraHeight : 132)
        case .system:
            let rows = max(0, systemRows)
            contentHeight = NotchLayout.chromeHeight
                + (rows == 0 ? 160 : CGFloat(rows) * 96 + CGFloat(rows - 1) * 10)
        case .files: contentHeight = fileMediaHeight.map { NotchLayout.chromeHeight + $0 } ?? 336
        case .clipboard, .dictation: contentHeight = 340
        case .captures: contentHeight = capturePreviewHeight.map { NotchLayout.chromeHeight + $0 + 4 } ?? 340
        case .timer:
            let timer: CGFloat
            switch timerMode {
            case .timer: timer = timerHasSession ? 96 : 208
            case .pomodoro: timer = timerHasSession ? 118 : 376
            case .stopwatch: timer = timerHasSession ? 96 : 114
            }
            contentHeight = NotchLayout.chromeHeight + timer
        case .camera: contentHeight = NotchLayout.chromeHeight + (expandedWidth - NotchLayout.horizontalInset * 2) * 0.75 + 50
        case .tools, .calendar, .notifications, .downloads: contentHeight = 400
        case .notes: contentHeight = NotchLayout.chromeHeight + 440
        }
        let showsCapturePreview = module == .captures && !detail && capturePreviewHeight != nil
        let fillsHeight = detail || (!showsCapturePreview && [.mixer, .clipboard, .dictation, .captures, .tools, .notes].contains(module))
        var preferredHeight = safeContentTop + (detail ? 440 : contentHeight)
        if layout == .custom {
            preferredHeight = fillsHeight ? customHeight : min(preferredHeight, customHeight)
        }
        let width: CGFloat
        switch module {
        case .notes where !detail: width = notesWidth
        default: width = expandedWidth
        }
        return CGSize(width: width, height: min(preferredHeight, screen.height - 48 - quickAccessBottomInset))
    }
    /// The mirror is the whole page: the picture fills the silhouette edge to
    /// edge under the cutout, at 4:3, so the island takes its shape. Across a
    /// panoramic panel a 4:3 picture would outgrow most screens, so there it
    /// keeps a narrower page. A custom size is a height the person chose, so
    /// the picture is cropped to it rather than let past it.
    var mirrorSize: CGSize {
        let width = isPanoramic ? min(600, expandedWidth) : expandedWidth
        var height = cameraHeight + width * 0.75
        if layout == .custom { height = min(height, customHeight) }
        return CGSize(width: width, height: min(height, screen.height - 48 - quickAccessBottomInset))
    }
    /// Notes keeps its list beside the note being written, which needs room
    /// for two columns rather than the one every other module lays out in.
    var notesWidth: CGFloat {
        min(max(expandedWidth, 720), screen.width - 24 - NotchQuickAccessLayout.gutter * 2)
    }
    /// A panoramic Home lays every module on a single row.
    var sectionColumns: Int { isPanoramic ? NotchModule.allCases.count : expandedWidth >= 440 ? 4 : 2 }

    func sectionPickerSize(count: Int, searching: Bool = false, cardRows: [[NotchHomeCard]] = []) -> CGSize {
        let columns = searching ? 1 : sectionColumns
        let rows = max(1, (count + columns - 1) / columns)
        let tileHeight = searching ? NotchLayout.sectionResultHeight
            : isPanoramic ? NotchLayout.dockTileHeight : NotchLayout.sectionTileHeight
        var results = count == 0 ? 160 : CGFloat(rows) * tileHeight
            + CGFloat(rows - 1) * NotchLayout.sectionSpacing + 4
        if !searching {
            results += cardRows.map { NotchHomeCard.rowHeight($0, panoramic: isPanoramic) }.reduce(0, +)
                + CGFloat(cardRows.count) * NotchLayout.sectionSpacing
        }
        let content = NotchLayout.sectionSearchHeight + 12 + results
        let desiredHeight = safeContentTop + NotchLayout.chromeHeight + content
        let limit = layout == .custom ? customHeight : 580
        return CGSize(width: expandedWidth, height: min(desiredHeight, limit, screen.height - 48 - quickAccessBottomInset))
    }

    func contentSize(for size: CGSize) -> CGSize {
        CGSize(width: max(0, size.width - NotchLayout.horizontalInset * 2),
               height: max(0, size.height - safeContentTop - NotchLayout.chromeHeight))
    }
    /// Settings pages are laid out for their own window, so this page asks for
    /// that window's design size inside the panel's chrome, whatever size the
    /// modules use, and gives up only what the screen cannot hold.
    var settingsSize: CGSize {
        CGSize(width: min(CGFloat(SettingsWindowSupport.minContentWidth) + NotchLayout.horizontalInset * 2,
                          screen.width - 24 - NotchQuickAccessLayout.gutter * 2),
               height: min(safeContentTop + NotchLayout.chromeHeight + CGFloat(SettingsWindowSupport.minContentHeight),
                           screen.height - 48 - quickAccessBottomInset))
    }
    /// The first run owns the whole panel, whatever size the modules use. Each
    /// page asks for the height its content needs, so the island grows and
    /// shrinks as the steps change; the tool picker is the tallest.
    func onboardingSize(for step: OnboardingStep) -> CGSize {
        let content: CGFloat
        switch step {
        case .welcome: content = 250
        case .howItWorks: content = 318
        case .tools: content = 500
        case .access: content = 330
        }
        return CGSize(width: min(680, screen.width - 24),
                      height: min(safeContentTop + content, screen.height - 48))
    }
    func frame(for size: CGSize) -> CGRect {
        CGRect(x: screen.midX - size.width / 2,
               y: screen.maxY - size.height,
               width: size.width, height: size.height)
    }

    func contains(_ point: CGPoint, in size: CGSize) -> Bool {
        let frame = self.frame(for: size)
        // Match the flipped native view: the top edge belongs to the island.
        return CGRect(origin: .zero, size: size).contains(
            CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y))
    }
}

struct NotchSessionState {
    var locked = false
    var sleeping = false
    var displaysSleeping = false
    var onConsole = true
    var canRunTimer: Bool { !locked && !sleeping && onConsole }
    var canPresent: Bool { canRunTimer && !displaysSleeping }
}

/// Reserve enough backing space for both ends. The visible silhouette moves
/// inside it; the native window only shrinks after the transition finishes.
enum NotchMotion {
    static func duration(from: CGSize, to: CGSize) -> TimeInterval {
        let grows = to.height > from.height || (to.height == from.height && to.width > from.width)
        return grows ? 0.34 : 0.26
    }

    static func envelope(from: CGSize, to: CGSize) -> CGSize {
        CGSize(width: max(from.width, to.width), height: max(from.height, to.height))
    }
}

/// Free room on both sides of the camera, in Cocoa screen coordinates.
/// Unknown/occupied camera space is distinct from a known zero-width wing.
enum NotchMenuBarLayout {
    static func sideRoom(screen: CGRect, cameraWidth: CGFloat, barHeight: CGFloat,
                         occupied: [CGRect]) -> CGFloat? {
        let bar = CGRect(x: screen.minX, y: screen.maxY - barHeight, width: screen.width, height: barHeight)
        let camera = CGRect(x: screen.midX - cameraWidth / 2, y: bar.minY,
                            width: cameraWidth, height: barHeight)
        var left = screen.minX + 8
        var right = screen.maxX - 8
        for rect in occupied where rect.intersects(bar) {
            guard rect.minX.isFinite, rect.maxX.isFinite, rect.width > 0 else { return nil }
            if rect.intersects(camera) { return nil }
            if rect.maxX <= camera.minX { left = max(left, rect.maxX + 8) }
            if rect.minX >= camera.maxX { right = min(right, rect.minX - 8) }
        }
        return max(0, min(camera.minX - left, right - camera.maxX))
    }
}
