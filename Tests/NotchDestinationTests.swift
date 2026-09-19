// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Carbon.HIToolbox

/// Production opening and availability methods run with inert presentation
/// doubles. Feature choices live only in a disposable test preferences domain.
enum NotchDestinationContract {
    enum ReviewDefaults { static var current: UserDefaults! }
    enum NotchContentTransition { case none, reveal, replace, dismiss }
    final class Panel {
        var acceptsKeyFocus = false
        func makeKey() {}
        func resignKey() {}
    }
    final class ClipboardAIService {
        struct Run {
            let action: ClipboardAIAction
            var module = NotchModule.clipboard
        }
        static var shared = ClipboardAIService()
        var run: Run?
        func dismiss() { run = nil }
    }
    final class Host { func containsHover(_ point: CGPoint) -> Bool { false } }
    enum NSEvent { static let mouseLocation = CGPoint.zero }
    final class AppDelegate { func closePopover(preservingNotch: Bool) {} }
    struct Application { let delegate: AnyObject? = nil }
    static let NSApp = Application()
    enum ClipboardHistoryService {
        static let shared = Reader()
        struct Reader { func rememberPasteTarget() {} }
    }
    enum QuickLauncherService { static var shared = QuickLauncherContract.Launcher() }
    final class Timer {
        var running = true
        var syncs = 0
        var suspensions = 0
        func syncWithPreferences() { running = true; syncs += 1 }
        func suspend() { running = false; suspensions += 1 }
    }
    enum NotchTimerService { static var shared = Timer() }
    enum PreciseVolumeRollerService {
        static let shared = Service()
        struct Service { func syncWithPreferences() {} }
    }

    class State {
        var running = true
        var session = NotchSessionState()
        var suspended: Bool { !session.canPresent }
        var panel: Panel? = Panel()
        var windowHost: Host? = Host()
        var modules: [NotchModule] = []
        var selected = NotchModule.controls
        var selectedMetric: MetricDetailKind?
        var expanded = false
        var showingSettings = false
        var showingOnboarding = false
        var revealedOnboarding = 0
        var showingSections = false
        var peeking = false
        var pinned = false
        var openedByHover = false
        var inside = false
        var hoverState = NotchHoverState()
        var hoverWork: DispatchWorkItem?
        var requestedDetail: MetricDetailKind?
        var presentationSyncs = 0
        var presentationTearDowns = 0
        var captureControlsCancel: (() -> Void)?
        var captureClose: (() -> Void)?
        var captureControls: Int?
        var heldDrag = false
        var sectionQuery = ""
        var highlightedSection: NotchModule?
        var detailOrigin: NotchModule?
        var closedAt: TimeInterval?
        func removeEventMonitors() {}
        func mutatePresentation(transitionContent: NotchContentTransition, _ change: () -> Void) { change() }
        func installEventMonitors() {}
        func revealOnboarding() { revealedOnboarding += 1; expanded = true }
        func syncVisibleConsumers() { requestedDetail = selectedMetric }
        func provideHapticFeedback() {}
        func endCaptureControls() {}
        func clearCapture() { captureControlsCancel = nil; captureClose = nil }
        func tearDownPresentation() { expanded = false; presentationTearDowns += 1 }
    }

    static func run(expect: (Bool, String) -> Void) {
        let domain = "com.f4.tests.notch-destinations"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        ReviewDefaults.current = defaults
        let previousLauncherDefaults = QuickLauncherContract.ReviewDefaults.current
        QuickLauncherContract.ReviewDefaults.current = defaults
        defer {
            QuickLauncherContract.ReviewDefaults.current = previousLauncherDefaults
            ReviewDefaults.current = nil
            defaults.removePersistentDomain(forName: domain)
            QuickLauncherService.shared = QuickLauncherContract.Launcher()
            NotchTimerService.shared = Timer()
        }
        for (key, value) in Defaults.registeredDefaults where key.hasPrefix("notch") { defaults.set(value, forKey: key) }
        for feature in AppFeature.allCases { defaults.set(true, forKey: feature.availabilityKey) }
        reopeningContracts(defaults: defaults, expect: expect)
        navigationContracts(expect: expect)
        resumeContracts(expect: expect)
        onboardingContracts(expect: expect)
        for resting in [NotchIdleContent.none, .music] {
            defaults.set(resting.rawValue, forKey: DefaultsKey.notchIdleContent)
            defaults.set(false, forKey: DefaultsKey.notchShowPlayingMusic)
            let service = Service()
            service.open(.music)
            expect(service.expanded && service.selected == .music && service.panel?.acceptsKeyFocus == true,
                   "hiding automatic music preserves explicit opening of its controls")
            service.open(.controls)
            expect(service.expanded && service.selected == .controls
                   && NotchSupport.controls(in: defaults).contains(.music),
                   "hiding automatic music preserves playback controls on the island's home page")
        }
        defaults.set(NotchIdleContent.music.rawValue, forKey: DefaultsKey.notchIdleContent)
        defaults.set(true, forKey: DefaultsKey.notchShowPlayingMusic)
        let families: [(MetricDetailKind, AppFeature)] = [
            (.cpu, .monitorCPU), (.gpu, .monitorGPU), (.memory, .monitorMemory),
            (.network, .monitorNetwork), (.disk, .monitorDisk),
            (.battery, .monitorPower), (.power, .monitorPower), (.fan, .fanControl),
        ]
        for (metric, feature) in families {
            let service = Service()
            service.open(.system, pinned: true, metric: metric)
            expect(service.selectedMetric == metric, "an available metric opens its own detail")
            defaults.set(false, forKey: feature.availabilityKey)
            service.syncWithPreferences()
            expect(service.selectedMetric == nil && service.requestedDetail == nil,
                   "removing the selected metric clears its detail even when other system families remain")
            service.open(.system, metric: metric, sections: true)
            service.open(.system, metric: metric)
            expect(service.selectedMetric == nil,
                   "a retained gallery argument cannot restore a metric removed from the hub")
            defaults.set(true, forKey: feature.availabilityKey)
        }
        let service = Service()
        service.open(.system, metric: .cpu)
        for (_, feature) in families { defaults.set(false, forKey: feature.availabilityKey) }
        service.syncWithPreferences()
        expect(!service.modules.contains(.system) && service.selected == .controls
               && service.selectedMetric == nil && service.requestedDetail == nil,
               "removing the last system family selects an available module without keeping its old detail")
        defaults.set(true, forKey: AppFeature.fanControl.availabilityKey)
        service.open(.system, metric: .fan)
        expect(!service.modules.contains(.system) && service.selectedMetric == .fan,
               "a separately installed fan feature retains its direct detail without other system modules")

        QuickLauncherService.shared = QuickLauncherContract.Launcher()
        let launcher = QuickLauncherService.shared
        let firstPresentation = launcher.presentationID
        service.open(.tools)
        expect(service.selected == .tools && launcher.selectedIndex == 0 && launcher.presentationID != firstPresentation,
               "opening Tools inside the island prepares keyboard selection on its first presentation")
        QuickLauncherContract.events.removeAll()
        let enter = QuickLauncherContract.NSEvent(keyCode: UInt16(kVK_Return))
        expect(launcher.handlePanelKey(enter, columns: NotchSupport.toolColumns) == nil
               && QuickLauncherContract.events == ["keepAwake.toggle"],
               "Return works immediately after the island opens Tools")
        let unchangedPresentation = launcher.presentationID
        service.open(.tools)
        expect(launcher.presentationID == unchangedPresentation,
               "reopening the same visible Tools destination does not reset its working presentation")
        launcher.activeUtility = .urlCleaner
        service.open(.controls)
        service.open(.tools)
        expect(launcher.activeUtility == .urlCleaner,
               "navigation preserves a still-available hosted utility")
        service.open(.controls)
        defaults.set(false, forKey: AppFeature.urlCleaner.availabilityKey)
        service.open(.tools)
        expect(launcher.activeUtility == nil,
               "returning to Tools after removal cannot revive its previous utility")
        service.open(.controls)
        launcher.candidates = []
        service.open(.tools)
        expect(launcher.selectedIndex == nil, "an empty Tools module leaves keyboard activation without a target")
        sessionContracts(expect: expect)
    }

    private static func reopeningContracts(defaults: UserDefaults, expect: (Bool, String) -> Void) {
        expect(Defaults.registeredDefaults[DefaultsKey.notchReturnHome] as? Bool == false,
               "returning home is opt-in and preserves the existing opening behavior")
        expect(Defaults.registeredDefaults[DefaultsKey.notchHomeModule] as? String == NotchModule.controls.rawValue,
               "the previously available home option keeps Controls as its initial destination")
        for returnHome in [false, true] {
            defaults.set(returnHome, forKey: DefaultsKey.notchReturnHome)
            let payload = SettingsBackupSupport.payload(appVersion: "test") {
                if $0 == DefaultsKey.notchReturnHome { return returnHome }
                if $0 == DefaultsKey.notchHomeModule { return NotchModule.music.rawValue }
                if $0 == DefaultsKey.notchHideUntilHover { return true }
                if $0 == DefaultsKey.notchHoverDelay { return 0.65 }
                return nil
            }
            let data = try? JSONSerialization.data(withJSONObject: payload)
            let decoded = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let restored = decoded.flatMap { SettingsBackupSupport.sanitizedSettings(from: $0) }
            expect(restored?[DefaultsKey.notchReturnHome] as? Bool == returnHome
                   && restored?[DefaultsKey.notchHomeModule] as? String == NotchModule.music.rawValue
                   && restored?[DefaultsKey.notchHoverDelay] as? Double == 0.65
                   && restored?[DefaultsKey.notchHideUntilHover] as? Bool == true,
                   "the opening behavior, selected page and activation time survive backup and restore")

            let service = Service()
            service.open(.files)
            service.open()
            expect(service.selected == .files, "an already open island does not jump away from the current page")
            service.expanded = false
            service.open()
            expect(service.selected == (returnHome ? .controls : .files),
                   "reopening either restores the last page or returns home according to the preference")
            service.expanded = false
            service.open(.music)
            expect(service.selected == .music, "an explicit destination always wins over the opening preference")
            defaults.set("controls", forKey: DefaultsKey.notchHiddenModules)
            defaults.set("files,music", forKey: DefaultsKey.notchModuleOrder)
            service.expanded = false
            service.open()
            expect(service.selected == (returnHome ? .files : .music),
                   "a hidden home page falls back to the first visible page without unhiding controls")
            defaults.set("", forKey: DefaultsKey.notchHiddenModules)
            defaults.set("", forKey: DefaultsKey.notchModuleOrder)
        }
        defaults.set(true, forKey: DefaultsKey.notchReturnHome)
        for page in NotchSupport.modules(in: defaults) {
            defaults.set(page.rawValue, forKey: DefaultsKey.notchHomeModule)
            let service = Service()
            service.open()
            expect(service.selected == page, "each available page can be chosen for reopening: \(page.rawValue)")
            service.open(.files)
            expect(service.selected == .files, "a saved opening page never overrides explicit navigation")
            defaults.set(page.rawValue, forKey: DefaultsKey.notchHiddenModules)
            service.expanded = false
            service.open()
            expect(service.selected == NotchSupport.modules(in: defaults).first,
                   "hiding the saved opening page falls back to an available page")
            defaults.set("", forKey: DefaultsKey.notchHiddenModules)
        }
        defaults.set("unknown-page", forKey: DefaultsKey.notchHomeModule)
        let invalid = Service()
        invalid.open()
        expect(invalid.selected == .controls, "a malformed saved page falls back to Controls")
        defaults.set(NotchModule.controls.rawValue, forKey: DefaultsKey.notchHomeModule)
        defaults.set(false, forKey: DefaultsKey.notchReturnHome)
    }

    /// The first run owns the panel: nothing that normally closes it or
    /// swaps its page may do either while it shows.
    private static func onboardingContracts(expect: (Bool, String) -> Void) {
        let service = Service()
        service.open(.controls)
        service.showingOnboarding = true
        service.collapse()
        service.handleEscape()
        expect(service.expanded && service.showingOnboarding,
               "neither a collapse nor Escape closes the first run")
        service.open(.clipboard)
        service.toggleSections()
        expect(service.selected == .controls && !service.showingSections && service.revealedOnboarding == 2,
               "a route to another page brings the first run back instead of replacing it")
        service.expanded = false
        service.open(sections: true)
        expect(service.expanded && !service.showingSections && service.revealedOnboarding == 3,
               "reopening a stepped-aside first run shows it again, not Home")
        service.showingOnboarding = false
        service.collapse()
        expect(!service.expanded, "once the first run ends the panel closes normally again")
    }

    private static func navigationContracts(expect: (Bool, String) -> Void) {
        ClipboardAIService.shared = ClipboardAIService()
        defer { ClipboardAIService.shared = ClipboardAIService() }

        /// Presses Escape until the panel closes, failing on any page it has
        /// already visited: a revisit with the same flags can only loop.
        func escapesToClosed(_ service: Service, _ start: String) {
            var seen: [[NotchDestination]] = []
            for _ in 0..<8 where service.expanded {
                let here = service.path
                expect(!seen.contains(here), "Escape never returns to a page it already left: \(start)")
                guard !seen.contains(here) else { return }
                seen.append(here)
                service.handleEscape()
            }
            expect(!service.expanded, "repeated Escape always ends by closing the panel: \(start)")
        }

        let orphanMetric = Service()
        orphanMetric.open(.system, metric: .cpu)
        expect(orphanMetric.path == [.sections, .metric(.cpu)], "a reading with no known origin hangs under Explore")
        escapesToClosed(orphanMetric, "reading without origin")

        let fromControls = Service()
        fromControls.open(.controls)
        fromControls.showMetric(.network)
        expect(fromControls.path == [.sections, .module(.controls), .metric(.network)],
               "a reading opened from Controls keeps Controls in its trail")
        fromControls.handleEscape()
        expect(fromControls.path == [.sections, .module(.controls)], "Escape returns a reading to where it was opened")
        escapesToClosed(fromControls, "reading from Controls")

        let overlay = Service()
        overlay.open(.music)
        overlay.toggleSections()
        expect(overlay.path == [.sections], "Explore opens from any page")
        overlay.handleEscape()
        expect(overlay.path == [.sections, .module(.music)], "Escape on an Explore opened over a page returns to that page")
        escapesToClosed(overlay, "Explore over Music")

        let crumbs = Service()
        crumbs.showSettings()
        crumbs.navigate(to: .sections)
        expect(crumbs.path == [.sections] && !crumbs.showingSettings, "the Explore crumb leaves the page below it")
        escapesToClosed(crumbs, "Explore crumb")

        let settings = Service()
        settings.open(.music)
        expect(settings.showSettings() && settings.path == [.sections, .settings]
               && settings.panel?.acceptsKeyFocus == true,
               "Settings opens as a page of its own under Explore, ready for typing")
        settings.toggleSections()
        settings.handleEscape()
        expect(settings.path == [.sections, .settings], "Explore opened over Settings hands Settings back")
        settings.handleEscape()
        expect(settings.expanded && settings.path == [.sections] && !settings.showingSettings,
               "Escape on Settings goes up to Explore before it closes the panel")
        settings.showSettings()
        escapesToClosed(settings, "Settings")
        settings.showSettings()
        settings.select(.music)
        expect(settings.path == [.sections, .module(.music)] && !settings.showingSettings,
               "choosing a module leaves Settings")
        settings.showSettings()
        settings.collapse()
        expect(!settings.showingSettings, "closing the panel closes Settings with it")
        settings.open()
        expect(!settings.showingSettings, "the panel does not reopen on Settings once closed")
        settings.collapse()
        settings.captureControls = 1
        expect(!settings.showSettings() && !settings.showingSettings,
               "capture controls own the panel, so Settings is left to its window")
        settings.captureControls = nil
        settings.running = false
        expect(!settings.showSettings(), "a notch that cannot present leaves Settings to its window")

        let ai = Service()
        ai.open(.clipboard)
        ClipboardAIService.shared.run = .init(action: .summarize)
        expect(ai.path == [.sections, .module(.clipboard), .clipboardAI(.summarize)],
               "a clipboard answer sits under Clipboard in the trail")
        ai.open(.clipboard)
        expect(ClipboardAIService.shared.run != nil, "reopening Clipboard keeps the answer on screen")
        ai.navigate(to: .module(.clipboard))
        expect(ClipboardAIService.shared.run == nil && ai.path == [.sections, .module(.clipboard)],
               "the Clipboard crumb leads out of the answer back to the list")
        for leave in [{ ai.select(.music) }, { ai.toggleSections() }, { ai.showMetric(.cpu) },
                      { _ = ai.showSettings() }] {
            ai.open(.clipboard)
            ClipboardAIService.shared.run = .init(action: .translate)
            leave()
            expect(ClipboardAIService.shared.run == nil,
                   "leaving Clipboard by any route discards the answer instead of resurfacing it later")
        }

        let spoken = Service()
        spoken.open(.dictation)
        ClipboardAIService.shared.run = .init(action: .toneFormal, module: .dictation)
        expect(spoken.path == [.sections, .module(.dictation), .clipboardAI(.toneFormal)],
               "an answer about a dictation sits under Dictation in the trail")
        spoken.open(.dictation)
        expect(ClipboardAIService.shared.run != nil, "reopening Dictation keeps its answer on screen")
        spoken.goBack()
        expect(ClipboardAIService.shared.run == nil && spoken.path == [.sections, .module(.dictation)],
               "going back from the answer returns to the dictation list")
        ClipboardAIService.shared.run = .init(action: .summarize, module: .dictation)
        spoken.open(.clipboard)
        expect(ClipboardAIService.shared.run == nil,
               "opening another list discards an answer that belongs to Dictation")
        spoken.open(.dictation)
        ClipboardAIService.shared.run = .init(action: .summarize)
        expect(spoken.path == [.sections, .module(.dictation)],
               "a clipboard answer never names itself under Dictation")
        ClipboardAIService.shared.run = nil
    }

    private static func resumeContracts(expect: (Bool, String) -> Void) {
        let window = NotchSupport.resumeWindow
        expect(!NotchSupport.reopensAtHome(closedAt: nil, now: 100)
               && !NotchSupport.reopensAtHome(closedAt: 100, now: 100 + window)
               && NotchSupport.reopensAtHome(closedAt: 100, now: 100 + window + 1)
               && !NotchSupport.reopensAtHome(closedAt: .nan, now: 500),
               "a closed panel resumes its page for the resume window and no longer")

        let service = Service()
        service.open(.music)
        service.collapse()
        service.open()
        expect(service.selected == .music && !service.showingSections,
               "reopening straight after closing resumes the page that was open")
        service.collapse()
        service.closedAt = ProcessInfo.processInfo.systemUptime - window - 1
        service.open()
        expect(service.showingSections && service.path == [.sections],
               "reopening after the resume window starts at Home")
        service.collapse()
        service.closedAt = ProcessInfo.processInfo.systemUptime - window - 1
        service.open(.files)
        expect(service.selected == .files && !service.showingSections,
               "a named page still wins after the resume window")
    }

    private static func sessionContracts(expect: (Bool, String) -> Void) {
        let service = Service()
        NotchTimerService.shared = Timer()
        let timer = NotchTimerService.shared
        service.updateSession { $0.displaysSleeping = true }
        expect(timer.running && timer.suspensions == 0 && timer.syncs == 0
               && service.presentationTearDowns == 1 && !service.session.canPresent,
               "display sleep removes presentation while leaving the timer and alarm uninterrupted")
        service.updateSession { $0.sleeping = true }
        expect(!timer.running && timer.suspensions == 1 && service.presentationTearDowns == 1,
               "system sleep suspends the timer even after the display already hid the island")
        service.updateSession { $0.locked = true }
        service.updateSession { $0.displaysSleeping = false }
        service.updateSession { $0.sleeping = false }
        expect(!timer.running && timer.syncs == 0 && service.presentationSyncs == 0,
               "display and system wake cannot resume an alarm or presentation while the session is locked")
        service.updateSession { $0.locked = false }
        expect(timer.running && timer.syncs == 1 && service.presentationSyncs == 1,
               "unlocking after every sleep condition clears resumes through the normal presentation path once")

        service.updateSession { $0.displaysSleeping = true }
        service.updateSession { $0.onConsole = false }
        expect(!timer.running && timer.suspensions == 2,
               "switching users suspends an alarm even when the display is already asleep")
        service.updateSession { $0.onConsole = true }
        expect(timer.running && timer.syncs == 2 && service.presentationSyncs == 1 && !service.session.canPresent,
               "returning to the same awake session resumes only the timer while its display remains asleep")
        service.updateSession { $0.displaysSleeping = false }
        expect(timer.running && service.presentationSyncs == 2,
               "the island returns only after the display also wakes")
        service.updateSession { $0.displaysSleeping = true }
        service.updateSession { $0.locked = true }
        service.updateSession { $0.onConsole = false }
        service.updateSession { $0.locked = false }
        service.updateSession { $0.displaysSleeping = false }
        expect(!timer.running && service.presentationSyncs == 2,
               "unlock and display wake cannot resume work while another login session owns the console")
        service.running = false
        service.updateSession { $0.onConsole = true }
        expect(!timer.running && service.presentationSyncs == 2,
               "late session notifications cannot restart a stopped island or timer")
    }
}
