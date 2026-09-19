// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import Foundation

/// The first run, one page of the notch at a time. The raw value is the
/// persisted resume point (`DefaultsKey.onboardingStep`): granting Screen
/// Recording makes macOS relaunch the app, and the flow comes back on the
/// page it left.
enum OnboardingStep: Int, CaseIterable {
    case welcome, howItWorks, tools, access

    static func stored(in defaults: UserDefaults = .standard) -> OnboardingStep {
        OnboardingStep(rawValue: defaults.integer(forKey: DefaultsKey.onboardingStep)) ?? .welcome
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// What the first run offers to install, named by what it does rather than by
/// the catalog's one entry per switch. A tool is the handful of catalog
/// features that only make sense together, so ticking it installs all of
/// them and unticking it removes all of them.
enum OnboardingTool: String, CaseIterable, Identifiable {
    case system, keepAwake, mixer, captures, calendar, timer, commandBar, windows, files, downloads, launcher

    var id: String { rawValue }

    var features: [AppFeature] {
        switch self {
        case .system: return [.monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork, .monitorDisk, .monitorPower]
        case .keepAwake: return [.keepAwake]
        case .mixer: return [.mixer]
        case .captures: return [.screenshot, .screenRecorder, .screenOCR, .colorPicker]
        case .calendar: return [.notchCalendar]
        case .timer: return [.notchTimer]
        case .commandBar: return [.commandBar]
        case .windows: return [.windowLayout]
        case .files: return [.shelf]
        case .downloads: return [.notchDownloads]
        case .launcher: return [.quickLauncher]
        }
    }

    /// Switched on with a fresh install, so the tool works the moment it is
    /// ticked instead of arriving as one more setting to find.
    var enableKeys: [String] {
        switch self {
        case .commandBar: return [DefaultsKey.commandBarShortcutEnabled]
        case .files: return [DefaultsKey.shelfEnabled]
        case .calendar: return [DefaultsKey.notchCalendarEnabled]
        case .timer: return [DefaultsKey.notchTimerEnabled]
        case .downloads: return [DefaultsKey.notchDownloadsEnabled]
        case .system, .keepAwake, .mixer, .captures, .windows, .launcher: return []
        }
    }

    var symbol: String {
        switch self {
        case .system: return "gauge.with.dots.needle.50percent"
        case .keepAwake: return "cup.and.saucer"
        case .mixer: return "slider.vertical.3"
        case .captures: return "camera.viewfinder"
        case .calendar: return "calendar"
        case .timer: return "timer"
        case .commandBar: return "command"
        case .windows: return "rectangle.split.2x1"
        case .files: return "tray.full"
        case .downloads: return "arrow.down.circle"
        case .launcher: return "square.grid.2x2"
        }
    }

    /// The everyday basics a clean install starts with.
    var startsSelected: Bool { self == .system || self == .keepAwake || self == .mixer }
}

enum OnboardingSupport {
    /// Installed on every Mac and never offered: the notch is the app, and
    /// clipboard history, dictation and the camera mirror are what it is for.
    /// Notes, Controls and Music are pages of the notch itself and have no
    /// switch at all.
    static var alwaysIncluded: Set<AppFeature> { Set(AppFeature.allCases.filter(\.isEssential)) }

    /// A clean install before the person has chosen anything.
    static var firstRunFeatures: Set<AppFeature> {
        alwaysIncluded.union(OnboardingTool.allCases.filter(\.startsSelected).flatMap(\.features))
    }

    /// A tool reads as installed while any of its features is, so a partly
    /// installed tool shows ticked rather than inviting a second install.
    static func tools(installed: Set<AppFeature>) -> Set<OnboardingTool> {
        Set(OnboardingTool.allCases.filter { !installed.isDisjoint(with: $0.features) })
    }

    /// The installed set after the picker: the chosen tools and the essentials
    /// replace whatever the offered tools had, and every feature the picker
    /// does not show keeps the state it already had.
    static func installedFeatures(choosing tools: Set<OnboardingTool>,
                                  installed: Set<AppFeature>) -> Set<AppFeature> {
        let offered = Set(OnboardingTool.allCases.flatMap(\.features))
        return installed.subtracting(offered)
            .union(tools.flatMap(\.features))
            .union(alwaysIncluded)
    }

    /// Only a tool being added turns its switches on; one that was already
    /// installed keeps whatever the person set it to.
    static func enableKeys(choosing tools: Set<OnboardingTool>, installed: Set<AppFeature>) -> [String] {
        let added = tools.subtracting(self.tools(installed: installed))
        return OnboardingTool.allCases.filter(added.contains).flatMap(\.enableKeys)
    }

    /// The grants worth asking for before the notch is handed over, in the
    /// order they are shown. Accessibility and the microphone serve the
    /// always-included dictation; Screen Recording only joins when a chosen
    /// tool needs it.
    static func permissions(choosing tools: Set<OnboardingTool>) -> [AppPermission] {
        let features = alwaysIncluded.union(tools.flatMap(\.features))
        let broad = Set(features.flatMap(\.onboardingPermissions))
        var permissions: [AppPermission] = [.accessibility, .screenRecording].filter(broad.contains)
        if features.contains(.dictation) { permissions.append(.microphone) }
        return permissions
    }
}
