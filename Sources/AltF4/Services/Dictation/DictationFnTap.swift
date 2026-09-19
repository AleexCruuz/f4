// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import AppKit

/// Reads Fn at the session event tap and keeps Fn's own events from every app
/// (`DictationFnKey`). It runs on a thread of its own: every keystroke passes
/// through an active tap, and typing must never wait on the main thread.
/// Creating it needs Accessibility; without it there is no tap.
final class DictationFnTap {
    /// Owned by the tap thread, so no callback can outlive it.
    private final class Reader {
        let report: (DictationFnKey.Event, TimeInterval) -> Void
        var tap: CFMachPort?

        init(report: @escaping (DictationFnKey.Event, TimeInterval) -> Void) {
            self.report = report
        }

        func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let key = DictationFnKey.classify(type: type,
                                              keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                              fnFlag: event.flags.contains(.maskSecondaryFn))
            if key != .ignored {
                let time = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { [report] in report(key, time) }
            }
            return DictationFnKey.swallows(key) ? nil : Unmanaged.passUnretained(event)
        }
    }

    private final class LoopBox {
        var loop: CFRunLoop?
    }

    private let box = LoopBox()

    /// `report` runs on the main thread.
    init?(report: @escaping (DictationFnKey.Event, TimeInterval) -> Void) {
        let reader = Reader(report: report)
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<Reader>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(reader).toOpaque()
        ) else { return nil }
        reader.tap = tap

        let box = box
        let started = DispatchSemaphore(value: 0)
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            box.loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            started.signal()
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            withExtendedLifetime(reader) {}
        }
        thread.name = "AltF4 Dictation Fn"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    deinit {
        if let loop = box.loop { CFRunLoopStop(loop) }
    }
}

/// The Globe key's system action, changed the way System Settings changes it.
/// Every app caches the action; the HIToolbox call also tells running apps to
/// read it again, which a plain preference write does not, so their Emoji &
/// Symbols shortcut would keep the Globe key until they relaunch.
enum DictationGlobeKey {
    private typealias GetFunction = @convention(c) () -> Int32
    private typealias UpdateFunction = @convention(c) (Int32) -> Void

    private static let getUsage: GetFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "TISGetFnUsageType") else { return nil }
        return unsafeBitCast(symbol, to: GetFunction.self)
    }()
    private static let updateUsage: UpdateFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "TISUpdateFnUsageType") else { return nil }
        return unsafeBitCast(symbol, to: UpdateFunction.self)
    }()

    private static let key = "AppleFnUsageType" as CFString
    private static let domain = "com.apple.HIToolbox" as CFString

    /// Remembered before it is changed, so a crash can still hand it back.
    /// Set even when it already reads "nothing": apps that cached an older
    /// action from a write that never told them drop it too.
    static func takeOver() {
        let current = action
        let remembered = UserDefaults.standard.object(forKey: DefaultsKey.dictationGlobeActionToRestore) as? Int
        if let current, let keep = DictationGlobeAction.toRemember(current: current, remembered: remembered) {
            UserDefaults.standard.set(keep, forKey: DefaultsKey.dictationGlobeActionToRestore)
        }
        set(DictationGlobeAction.doNothing)
    }

    static func giveBack() {
        let remembered = UserDefaults.standard.object(forKey: DefaultsKey.dictationGlobeActionToRestore) as? Int
        guard remembered != nil else { return }
        if let current = action, let restore = DictationGlobeAction.toRestore(current: current, remembered: remembered) {
            set(restore)
        }
        UserDefaults.standard.removeObject(forKey: DefaultsKey.dictationGlobeActionToRestore)
    }

    /// Nil when only the preference can be read and it was never written.
    private static var action: Int? {
        if let getUsage { return Int(getUsage()) }
        return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
    }

    private static func set(_ value: Int) {
        if let updateUsage {
            updateUsage(Int32(value))
            return
        }
        CFPreferencesSetValue(key, value as CFNumber, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
