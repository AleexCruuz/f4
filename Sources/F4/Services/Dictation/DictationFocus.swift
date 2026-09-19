// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import AppKit
import ApplicationServices
import os

/// Reads what has the keyboard, through the accessibility tree the paste
/// already needs permission for.
enum DictationFocus {
    private static let timeout: Float = 0.25

    /// Blocks on the frontmost app for up to a few hundred milliseconds, so it
    /// is called off the main thread.
    static func target() -> DictationPasteTarget {
        guard AXIsProcessTrusted() else { return .unknown }
        // Only the focused element is asked, never the application element:
        // a role read on that switches a Chromium app into full accessibility
        // mode for the rest of its life (issue #953).
        let app = NSWorkspace.shared.frontmostApplication
        let chromium = app?.bundleURL.map { DictationPasteTarget.isChromium(bundleEntries: entries(of: $0)) } ?? false
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            log(app, role: nil, target: .unknown)
            return .unknown
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        let target = DictationPasteTarget.classify(role: role as? String,
                                                   editableAncestor: has(element, "AXEditableAncestor"),
                                                   valueSettable: valueSettable,
                                                   insertionPoint: has(element, kAXSelectedTextRangeAttribute),
                                                   chromium: chromium)
        log(app, role: role as? String, target: target)
        return target
    }

    /// The app's frameworks and the helpers inside each framework.
    private static func entries(of bundle: URL) -> [String] {
        let manager = FileManager.default
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let names = (try? manager.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let helpers = names.filter { $0.hasSuffix(".framework") }.flatMap { name in
            (try? manager.contentsOfDirectory(
                atPath: frameworks.appendingPathComponent("\(name)/Versions/Current/Helpers").path)) ?? []
        }
        return names + helpers
    }

    private static func has(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success && value != nil
    }

    private static func log(_ app: NSRunningApplication?, role: String?, target: DictationPasteTarget) {
        #if F4_DEVELOPMENT
        Logger(subsystem: "com.f4.utils.dev", category: "dictation").notice(
            "focus app=\(app?.bundleIdentifier ?? "-", privacy: .public) role=\(role ?? "-", privacy: .public) target=\(String(describing: target), privacy: .public)")
        #endif
    }
}
