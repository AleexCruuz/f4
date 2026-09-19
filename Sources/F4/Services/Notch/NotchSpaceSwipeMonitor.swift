// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Watches the Dock's Space swipe without intercepting it, and asks the
/// window server whether a display is still sliding between Spaces. Both are
/// undocumented: a missing symbol or a refused tap leaves the island as it was.
final class NotchSpaceSwipeMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let changed: (NotchSpaceSwipe.Phase) -> Void

    init?(changed: @escaping (NotchSpaceSwipe.Phase) -> Void) {
        self.changed = changed
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << NotchSpaceSwipe.eventType,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<NotchSpaceSwipeMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type.rawValue == NotchSpaceSwipe.eventType else { return }
        func field(_ number: UInt32) -> Int64 {
            CGEventField(rawValue: number).map { event.getIntegerValueField($0) } ?? 0
        }
        guard let phase = NotchSpaceSwipe.phase(gestureType: field(NotchSpaceSwipe.gestureTypeField),
                                                motion: field(NotchSpaceSwipe.motionField),
                                                phase: field(NotchSpaceSwipe.phaseField)) else { return }
        changed(phase)
    }

    private typealias ConnectionFunction = @convention(c) () -> UInt32
    private typealias AnimatingFunction = @convention(c) (UInt32, CFString) -> Bool

    private static let connection: UInt32 = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") else { return 0 }
        return unsafeBitCast(symbol, to: ConnectionFunction.self)()
    }()

    private static let managedDisplayIsAnimating: AnimatingFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSManagedDisplayIsAnimating") else { return nil }
        return unsafeBitCast(symbol, to: AnimatingFunction.self)
    }()

    static func isAnimating(displayID: CGDirectDisplayID) -> Bool {
        guard connection != 0, let managedDisplayIsAnimating,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let identifier = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return false }
        return managedDisplayIsAnimating(connection, identifier)
    }
}
