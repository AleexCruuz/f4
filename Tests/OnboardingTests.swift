// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import Foundation

/// The first run in the notch: where it resumes, what each tool installs,
/// what the picker leaves alone and what it asks permission for.
enum OnboardingTests {
    static func run(_ suite: TestSuite) {
        steps(suite)
        tools(suite)
        selection(suite)
        permissions(suite)
        sizes(suite)
    }

    private static func steps(_ suite: TestSuite) {
        suite.expect(OnboardingStep.allCases.map(\.rawValue) == [0, 1, 2, 3],
                     "the persisted resume point numbers the four pages in order")
        let name = "OnboardingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        suite.expect(OnboardingStep.stored(in: defaults) == .welcome, "a clean install starts on the welcome page")
        defaults.set(OnboardingStep.access.rawValue, forKey: DefaultsKey.onboardingStep)
        suite.expect(OnboardingStep.stored(in: defaults) == .access,
                     "a relaunch while granting access comes back on the access page")
        defaults.set(9, forKey: DefaultsKey.onboardingStep)
        suite.expect(OnboardingStep.stored(in: defaults) == .welcome,
                     "a resume point from another version starts over instead of failing")
        suite.expect(OnboardingStep.welcome.previous == nil && OnboardingStep.access.next == nil
                     && OnboardingStep.tools.next == .access && OnboardingStep.tools.previous == .howItWorks,
                     "pages step forwards and back one at a time and stop at both ends")
    }

    private static func tools(_ suite: TestSuite) {
        let all = OnboardingTool.allCases.flatMap(\.features)
        suite.expect(OnboardingTool.allCases.allSatisfy { !$0.features.isEmpty && !$0.symbol.isEmpty },
                     "every tool installs something and shows an icon")
        suite.expect(Set(all).count == all.count, "no feature belongs to two tools")
        suite.expect(Set(all).isDisjoint(with: OnboardingSupport.alwaysIncluded),
                     "the picker never offers to remove an always-included feature")
        suite.expect(!all.contains(.fanControl), "no tool installs a feature whose hardware the Mac may lack")
        for tool in OnboardingTool.allCases {
            let own = Set(tool.features.flatMap(\.enabledKeys)
                + GlobalShortcutRole.allCases.filter { tool.features.contains($0.feature) }.flatMap(\.requiredEnableKeys))
            suite.expect(Set(tool.enableKeys).isSubset(of: own),
                         "a tool only switches on its own features and their shortcuts (\(tool.rawValue))")
        }
        suite.expect(OnboardingSupport.alwaysIncluded == [.notch, .clipboardHistory, .dictation, .cameraPreview],
                     "the notch, clipboard history, dictation and the camera are always installed")
        suite.expect(OnboardingSupport.firstRunFeatures
                        == OnboardingSupport.alwaysIncluded.union(
                            OnboardingTool.system.features + [.keepAwake, .mixer]),
                     "a clean install adds only the everyday basics to what is always included")
        let name = "OnboardingTests-\(UUID().uuidString)"
        let empty = UserDefaults(suiteName: name)!
        defer { empty.removePersistentDomain(forName: name) }
        suite.expect(NotchModule.notes.isAvailable(in: empty) && NotchModule.controls.isAvailable(in: empty)
                     && NotchModule.music.isAvailable(in: empty),
                     "Notes, Controls and Music need no install at all")
        for feature in OnboardingSupport.alwaysIncluded { empty.set(true, forKey: feature.availabilityKey) }
        for (key, value) in Defaults.registeredDefaults where key.hasPrefix("notch") { empty.set(value, forKey: key) }
        suite.expect(NotchSupport.modules(in: empty).contains(.camera),
                     "the camera sits on Home as soon as the app is installed, with nothing to switch on")
    }

    private static func selection(_ suite: TestSuite) {
        let installed: Set<AppFeature> = [.notch, .clipboardHistory, .dictation, .monitorCPU,
                                          .keepAwake, .scrollInverter]
        let ticked = OnboardingSupport.tools(installed: installed)
        suite.expect(ticked == [.system, .keepAwake],
                     "a tool with any feature installed shows ticked, one with none shows empty")
        let chosen = OnboardingSupport.installedFeatures(choosing: [.system, .captures], installed: installed)
        suite.expect(chosen.isSuperset(of: OnboardingTool.system.features)
                     && chosen.isSuperset(of: OnboardingTool.captures.features),
                     "ticking a tool installs all of its features")
        suite.expect(!chosen.contains(.keepAwake), "unticking a tool removes it")
        suite.expect(chosen.contains(.scrollInverter),
                     "a feature the picker does not show keeps the state it already had")
        suite.expect(OnboardingSupport.installedFeatures(choosing: [], installed: [])
                        == OnboardingSupport.alwaysIncluded,
                     "an empty choice still keeps what is always included")
        suite.expect(OnboardingSupport.enableKeys(choosing: [.commandBar, .files, .keepAwake], installed: installed)
                        == [DefaultsKey.commandBarShortcutEnabled, DefaultsKey.shelfEnabled],
                     "only tools being added switch on, so an installed one keeps its own settings")
        suite.expect(OnboardingSupport.enableKeys(choosing: [.commandBar], installed: [.commandBar]).isEmpty,
                     "keeping an installed tool never flips its switches back on")
    }

    private static func permissions(_ suite: TestSuite) {
        suite.expect(OnboardingSupport.permissions(choosing: []) == [.accessibility, .microphone],
                     "dictation alone asks for Accessibility and the microphone")
        suite.expect(OnboardingSupport.permissions(choosing: [.system, .keepAwake, .mixer, .timer])
                        == [.accessibility, .microphone],
                     "the everyday basics add no permission of their own")
        suite.expect(OnboardingSupport.permissions(choosing: [.captures])
                        == [.accessibility, .screenRecording, .microphone],
                     "screenshots add Screen Recording, shown after Accessibility")
    }

    private static func sizes(_ suite: TestSuite) {
        let geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                     safeAreaTop: 32, cameraWidth: 179)
        let heights = OnboardingStep.allCases.map { geometry.onboardingSize(for: $0).height }
        suite.expect(heights.max() == geometry.onboardingSize(for: .tools).height,
                     "the tool picker is the tallest page")
        suite.expect(OnboardingStep.allCases.allSatisfy {
                         geometry.onboardingSize(for: $0).width == geometry.onboardingSize(for: .welcome).width
                     }, "every page keeps one width, so only the height moves between them")
        let small = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 600, height: 400),
                                  safeAreaTop: 32, cameraWidth: 179)
        suite.expect(OnboardingStep.allCases.allSatisfy {
                         let size = small.onboardingSize(for: $0)
                         return size.width <= 600 - 24 && size.height <= 400 - 48
                     }, "a small screen keeps every page inside it")
    }
}
