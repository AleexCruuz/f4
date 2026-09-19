// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import Foundation

/// One page the panel can show. Everything reachable inside the notch is one of
/// these, which is what lets a single header describe any location.
enum NotchDestination: Equatable, Identifiable {
    /// The module gallery. The root of everything below it.
    case sections
    case module(NotchModule)
    /// The app's Settings, hosted by the panel instead of a window.
    case settings
    case metric(MetricDetailKind)
    /// A model answering for one clipboard entry or dictation. It names the
    /// action rather than the text, because the action is what the user chose
    /// and what the page is doing; the text is on the page itself.
    case clipboardAI(ClipboardAIAction)

    var id: String {
        switch self {
        case .sections: return "sections"
        case .module(let module): return "module.\(module.rawValue)"
        case .settings: return "settings"
        case .metric(let metric): return "metric.\(metric.rawValue)"
        case .clipboardAI(let action): return "clipboardAI.\(action.rawValue)"
        }
    }
}

/// The panel has no navigation stack of its own: what is on screen is decided
/// by a handful of independent flags on `NotchService`. Rather than keep a
/// second copy of that state in sync, the trail is rebuilt from those flags
/// every time it is read, so it can never disagree with what is drawn.
///
/// The one thing the flags cannot say is how the user arrived. A detail page
/// opened from Controls and the same page opened from System look identical
/// afterwards, so the origin is passed in and used for that middle crumb alone.
enum NotchNavigation {
    static func path(sections: Bool, settings: Bool = false, metric: MetricDetailKind?,
                     module: NotchModule, origin: NotchModule?, hasModules: Bool,
                     clipboardAI: ClipboardAIAction? = nil) -> [NotchDestination] {
        if sections { return [.sections] }
        if settings { return [.sections, .settings] }
        if let metric {
            guard let origin else { return [.sections, .metric(metric)] }
            return [.sections, .module(origin), .metric(metric)]
        }
        // Nothing is installed: there is no module page to name, and the empty
        // state that replaces it is not a destination the user navigated to.
        guard hasModules else { return [] }
        // A run belongs under the list that holds the text it is working on,
        // which is where its crumb has to lead back to.
        if let clipboardAI, module == .clipboard || module == .dictation {
            return [.sections, .module(module), .clipboardAI(clipboardAI)]
        }
        return [.sections, .module(module)]
    }
}
