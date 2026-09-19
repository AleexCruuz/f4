// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// One decision per physical scroll sequence. No timer is needed for wheel
/// devices without phases: the next event itself expires an old sequence.
struct NotchGestureSupport {
    enum Action: Equatable { case open, close, nextTrack, previousTrack }
    private enum Axis { case horizontal, vertical }
    private struct Origin {
        let vertical: Bool
        let horizontal: Bool
        let expanded: Bool
    }
    private var origin: Origin?
    private var axis: Axis?
    private var distance = 0.0
    private var fired = false
    private var lastTimestamp: TimeInterval?

    static func nativeInteraction(at view: NSView?) -> (control: Bool, scroll: Bool) {
        var control = false
        var scroll = false
        var view = view
        while let current = view {
            // The transparent opening button is the gesture surface itself.
            if (current is NSControl && !(current is NotchActivationButton)) || current is NSTextView {
                control = true
            }
            if current is NSScrollView { scroll = true }
            view = current.superview
        }
        return (control, scroll)
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        NotchSupport.isEnabled(in: defaults) && AppFeature.notchGestures.isAvailable(in: defaults)
            && defaults.bool(forKey: DefaultsKey.notchGesturesEnabled)
    }

    static func movement(_ delta: Double, precise: Bool, inverted: Bool) -> Double {
        guard delta.isFinite else { return 0 }
        return delta * (inverted ? 1 : -1) * (precise ? 1 : 24)
    }

    mutating func handle(x: Double, y: Double, timestamp: TimeInterval,
                         began: Bool, ended: Bool, momentum: Bool, precise: Bool, hasPhase: Bool,
                         allowVertical: Bool, allowHorizontal: Bool, expanded: Bool) -> Action? {
        guard timestamp.isFinite, x.isFinite, y.isFinite else { self = Self(); return nil }
        if ended || momentum { self = Self(); return nil }
        if hasPhase {
            if began {
                self = Self()
                origin = Origin(vertical: allowVertical, horizontal: allowHorizontal, expanded: expanded)
            }
            // AppKit keeps a phased scroll attached to its original view.
            // A blocked beginning stays blocked, and an interrupted sequence
            // cannot restart from a later changed event under another view.
            guard origin != nil else { return nil }
            if lastTimestamp.map({ timestamp < $0 }) == true { self = Self(); return nil }
        } else if origin != nil || began
                    || lastTimestamp.map({ timestamp < $0 || timestamp - $0 > 0.35 }) == true {
            self = Self()
        }
        lastTimestamp = timestamp
        guard !fired else { return nil }
        let allowVertical = origin?.vertical ?? allowVertical
        let allowHorizontal = origin?.horizontal ?? allowHorizontal
        let expanded = origin?.expanded ?? expanded
        if axis == nil {
            if precise, allowHorizontal, abs(x) > 0.2, abs(x) >= abs(y) * 1.5 { axis = .horizontal }
            else if allowVertical, abs(y) > 0.2, abs(y) >= abs(x) * 1.5 { axis = .vertical }
            else { return nil }
        }
        switch axis {
        case .horizontal where allowHorizontal:
            distance += x
            guard abs(distance) >= 40 else { return nil }
            fired = true
            return distance < 0 ? .nextTrack : .previousTrack
        case .vertical where allowVertical:
            distance += y
            guard abs(distance) >= 24 else { return nil }
            fired = true
            if distance > 0, !expanded { return .open }
            if distance < 0, expanded { return .close }
            return nil
        default:
            return nil
        }
    }
}

/// A trackpad swipe between Spaces carries the outgoing Space's windows with
/// it, the island included, away from the camera housing. The Dock receives
/// the swipe as undocumented window-server events; these are their fields.
struct NotchSpaceSwipe {
    enum Phase: Equatable { case moving, lifted }

    static let eventType: UInt32 = 30
    static let gestureTypeField: UInt32 = 110
    static let motionField: UInt32 = 123
    static let phaseField: UInt32 = 132
    /// The Space keeps sliding after the fingers lift. The window server
    /// reports a committed switch as animating, but not a bounce off the last
    /// Space, which comes to rest within this delay.
    static let settleDelay: TimeInterval = 0.5
    /// A lost end event must not keep the island hidden.
    static let staleAfter: TimeInterval = 4

    static func phase(gestureType: Int64, motion: Int64, phase: Int64) -> Phase? {
        // 23 is a Dock swipe and motion 1 its horizontal axis; the vertical
        // one opens Mission Control, which moves no Space.
        guard gestureType == 23, motion == 1 else { return nil }
        switch phase {
        case 1, 2: return .moving
        case 4, 8: return .lifted
        default: return nil
        }
    }

    private(set) var inProgress = false
    private var moving = false
    private var lastEvent: TimeInterval = 0

    /// True when the event starts a transition. A lift observed without its
    /// start began before observation and is ignored.
    mutating func record(_ phase: Phase, at time: TimeInterval) -> Bool {
        let starts = !inProgress && phase == .moving
        guard inProgress || starts else { return false }
        inProgress = true
        moving = phase == .moving
        lastEvent = time
        return starts
    }

    func isSettled(at time: TimeInterval, displayAnimating: Bool) -> Bool {
        guard inProgress else { return true }
        let quiet = time - lastEvent
        if quiet < 0 || quiet >= Self.staleAfter { return true }
        return !moving && !displayAnimating && quiet >= Self.settleDelay
    }
}
