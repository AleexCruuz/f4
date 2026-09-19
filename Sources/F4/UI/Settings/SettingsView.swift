// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// System-Settings-style window: a sidebar of pages on the left, the selected
/// page on the right. Scales cleanly as features are added, and gives each
/// feature a page of its own with room for examples and advanced options.
struct SettingsView: View {
    /// Set when Settings is a page of the notch instead of its own window.
    var notchSize: CGSize? = nil
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @AppStorage(DefaultsKey.superKeySource) private var superKeySourceRaw =
        SuperKeySource.capsLock.rawValue
    @State private var searchQuery = ""
    @State private var activeSearchIndex: Int?
    @FocusState private var sidebarSearchFocused: Bool

    private struct SearchResultsSnapshot: Equatable {
        let query: String
        let groups: [SettingsSearchGroup]

        var isBlank: Bool {
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var items: [SettingsSearchSuggestion] {
            groups.flatMap { group in
                (group.parentMatches ? [group.parentSuggestion] : []) + group.suggestions
            }
        }

        var ids: [SettingsSearchSuggestion.ID] { items.map(\.id) }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.query == rhs.query && lhs.ids == rhs.ids
        }
    }

    /// The one map of pages, shared with the command bar (SettingsDirectory).
    private var sidebarSections: [(title: String, items: [SettingsDirectoryItem])] {
        SettingsDirectory.sections(
            l10n.s,
            language: l10n.language,
            superKeySource: SuperKeySource.sanitized(superKeySourceRaw)
        )
    }

    var body: some View {
        let searchResults = SearchResultsSnapshot(
            query: searchQuery,
            groups: SettingsSearchSupport.groupedMatchingItems(
                query: searchQuery,
                items: SettingsDirectory.searchItems(l10n.s, language: l10n.language),
                isAvailable: { features.isAvailable($0) })
        )

        layout(searchResults: searchResults)
        .onAppear { ensureVisiblePage() }
        .onChange(of: features.revision) { _, _ in ensureVisiblePage() }
        .onChange(of: searchResults, initial: true) { previous, current in
            updateSearchSelection(previous: previous, current: current)
        }
        .onChange(of: router.requestID) { _, _ in
            searchQuery = ""
            activeSearchIndex = nil
            ensureVisiblePage()
        }
    }

    @ViewBuilder
    private func layout(searchResults: SearchResultsSnapshot) -> some View {
        if let notchSize {
            // The notch panel has no toolbar, which is where a split view puts
            // its sidebar toggle and where `.searchable` puts its field, so the
            // two columns and the search field are laid out here instead.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SidebarSearchField(query: $searchQuery, isFocused: $sidebarSearchFocused)
                    sidebarList(searchResults: searchResults)
                        .scrollContentBackground(.hidden)
                }
                .frame(width: 210)
                Divider()
                detailPane
            }
            .frame(width: notchSize.width, height: notchSize.height)
            .environment(\.notchPresentation, false)
            .tint(.accentColor)
            // SecureInputMonitor polls only while Settings is on screen, and it
            // learns that from whichever surface is showing Settings.
            .onAppear { SecureInputMonitor.shared.setSettingsWindowOpen(true) }
            .onDisappear {
                SecureInputMonitor.shared.setSettingsWindowOpen(appDelegate()?.settingsWindowIsVisible == true)
            }
        } else {
            NavigationSplitView {
                sidebar(searchResults: searchResults)
                    .navigationSplitViewColumnWidth(min: 198, ideal: 210, max: 240)
            } detail: {
                detailPane
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 772, maxWidth: .infinity, minHeight: 528, maxHeight: .infinity)
        }
    }

    // NavigationSplitView's detail slot sometimes queries its content for an
    // unconstrained ideal size (settling the divider, or on a page switch).
    // `List` answers that with its full content height rather than a viewport
    // size the way `ScrollView` does, and `.frame(maxHeight: .infinity)` only
    // bounds a size it is given, not one it is asked to report - so a few
    // hundred rows (Kill Process) grew the whole window. `GeometryReader`
    // reports the real space it was actually given for normal layout, and ~zero
    // when asked for an unconstrained ideal size, breaking the chain.
    private var detailPane: some View {
        GeometryReader { geometry in
            detail
                .settingsSectionFocus(for: router.page)
                .settingsPageSpacing()
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }

    /// macOS 27 backs the pinned sidebar search field with a hard top scroll
    /// edge, so rows fade out cleanly under it. On macOS 26 that effect does
    /// not render inside split-view sidebars and the pinned field has no
    /// backing of its own, so rows slid legibly across the placeholder
    /// (issues #183, #254); there the field lives on a fixed header above the
    /// list, where rows can never reach it. Earlier systems keep the classic
    /// opaque sidebar chrome.
    @ViewBuilder
    private func sidebar(searchResults: SearchResultsSnapshot) -> some View {
#if compiler(>=6.2)
        if #available(macOS 27, *) {
            sidebarList(searchResults: searchResults)
                .searchable(text: $searchQuery,
                            placement: .sidebar,
                            prompt: l10n.s.settingsSearchPlaceholder)
                .scrollEdgeEffectStyle(.hard, for: .top)
        } else if #available(macOS 26, *) {
            VStack(spacing: 0) {
                SidebarSearchField(query: $searchQuery, isFocused: $sidebarSearchFocused)
                sidebarList(searchResults: searchResults)
            }
        } else {
            sidebarList(searchResults: searchResults)
                .searchable(text: $searchQuery,
                            placement: .sidebar,
                            prompt: l10n.s.settingsSearchPlaceholder)
        }
#else
        sidebarList(searchResults: searchResults)
            .searchable(text: $searchQuery,
                        placement: .sidebar,
                        prompt: l10n.s.settingsSearchPlaceholder)
#endif
    }

    private var hasSearchQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func sidebarList(searchResults: SearchResultsSnapshot) -> some View {
        if hasSearchQuery {
            searchResultsList(searchResults)
        } else {
            normalSidebarList
        }
    }

    private var normalSidebarList: some View {
        List(selection: $router.page) {
            ForEach(sidebarSections, id: \.title) { section in
                let items = section.items.filter {
                    FeatureVisibilitySupport.isPageVisible($0.page) { $0.isAvailable }
                        && SettingsSearchSupport.matches(query: searchQuery, title: $0.title,
                                                         keywords: $0.keywords)
                }
                if !items.isEmpty {
                    Section(section.title) {
                        ForEach(items) { item in
                            Label {
                                Text(item.title)
                            } icon: {
                                Image(systemName: item.icon)
                                    // The sidebar's automatic icon tint can briefly disappear
                                    // while the window activates. Resolve it in the icon itself.
                                    .foregroundStyle(router.page == item.page
                                        ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            }
                            .padding(.vertical, 3)
                            .tag(item.page)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func searchResultsList(_ searchResults: SearchResultsSnapshot) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(searchResults.groups) { group in
                    searchPageRow(group, searchResults: searchResults)
                    ForEach(group.suggestions) { suggestion in
                        searchSuggestionRow(suggestion, searchResults: searchResults)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: activeSearchIndex) { _, index in
                guard let index, searchResults.items.indices.contains(index) else { return }
                let id = searchResults.items[index].id
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    proxy.scrollTo(id)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            .background {
                SearchKeyMonitor(customSearchFocused: sidebarSearchFocused) { keyCode in
                    handleSearchKey(keyCode, searchResults: searchResults.items)
                }
            }
        }
    }

    private func searchPageRow(_ group: SettingsSearchGroup,
                               searchResults: SearchResultsSnapshot) -> some View {
        let suggestion = group.parentSuggestion
        let selectionIndex = searchResults.items.firstIndex { $0.id == suggestion.id }
        let isSelected = selectionIndex == activeSearchIndex
        return Button {
            requestSearchItem(suggestion)
        } label: {
            Label(group.pageItem.title, systemImage: group.pageItem.icon)
                .fontWeight(.semibold)
                .searchResultRowStyle(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(suggestion.id)
    }

    private func searchSuggestionRow(_ suggestion: SettingsSearchSuggestion,
                                     searchResults: SearchResultsSnapshot) -> some View {
        let selectionIndex = searchResults.items.firstIndex { $0.id == suggestion.id }
        let isSelected = selectionIndex == activeSearchIndex
        return Button {
            requestSearchItem(suggestion)
        } label: {
            Label(suggestion.title, systemImage: suggestion.icon)
                .searchResultRowStyle(isSelected: isSelected)
                .padding(.leading, 18)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(suggestion.id)
    }

    private func handleSearchKey(_ keyCode: UInt16,
                                  searchResults: [SettingsSearchSuggestion]) -> Bool {
        switch keyCode {
        case 126: // Up
            guard !searchResults.isEmpty else { return false }
            activeSearchIndex = SettingsSearchSupport.moveSelection(
                index: activeSearchIndex, delta: -1, count: searchResults.count)
            return true
        case 125: // Down
            guard !searchResults.isEmpty else { return false }
            activeSearchIndex = SettingsSearchSupport.moveSelection(
                index: activeSearchIndex, delta: 1, count: searchResults.count)
            return true
        case 36, 76: // Return / Keypad Enter
            guard let index = activeSearchIndex,
                  searchResults.indices.contains(index) else { return false }
            requestSearchItem(searchResults[index])
            return true
        default:
            return false
        }
    }

    private func updateSearchSelection(previous: SearchResultsSnapshot,
                                       current: SearchResultsSnapshot) {
        guard !current.isBlank, !current.items.isEmpty else {
            activeSearchIndex = nil
            return
        }
        if previous.query != current.query {
            activeSearchIndex = 0
        } else if previous.ids != current.ids {
            activeSearchIndex = SettingsSearchSupport.reconciledSelection(
                index: activeSearchIndex,
                previousIDs: previous.ids,
                resultIDs: current.ids)
        }
    }

    private struct SearchKeyMonitor: NSViewRepresentable {
        var customSearchFocused: Bool
        var handleKey: (UInt16) -> Bool

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            context.coordinator.install(for: view)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            context.coordinator.customSearchFocused = customSearchFocused
            context.coordinator.handleKey = handleKey
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(customSearchFocused: customSearchFocused, handleKey: handleKey)
        }

        static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
            coordinator.removeMonitor()
        }

        final class Coordinator: NSObject {
            var customSearchFocused: Bool
            var handleKey: (UInt16) -> Bool
            private var monitor: Any?

            init(customSearchFocused: Bool, handleKey: @escaping (UInt16) -> Bool) {
                self.customSearchFocused = customSearchFocused
                self.handleKey = handleKey
            }

            func install(for view: NSView) {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                    [weak self, weak view] event in
                    guard let self, let view, let window = view.window,
                          event.window === window,
                          Self.isNavigationKey(event),
                          let editor = window.firstResponder as? NSTextView,
                          editor.isFieldEditor,
                          (customSearchFocused || Self.isSidebarSearchEditor(editor, near: view)),
                          !editor.hasMarkedText() else { return event }
                    return handleKey(event.keyCode) ? nil : event
                }
            }

            func removeMonitor() {
                guard let monitor else { return }
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }

            private static func isNavigationKey(_ event: NSEvent) -> Bool {
                let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                guard event.modifierFlags.intersection(blockedModifiers).isEmpty else { return false }
                return [UInt16(126), 125, 36, 76].contains(event.keyCode)
            }

            private static func isSidebarSearchEditor(_ editor: NSTextView,
                                                      near monitorView: NSView) -> Bool {
                guard let searchField = editor.delegate as? NSSearchField else { return false }
                let searchMidX = searchField.convert(searchField.bounds, to: nil).midX
                let sidebarFrame = monitorView.convert(monitorView.bounds, to: nil)
                return sidebarFrame.minX...sidebarFrame.maxX ~= searchMidX
            }
        }
    }

    private func requestSearchItem(_ suggestion: SettingsSearchSuggestion) {
        activeSearchIndex = nil
        let routed = SettingsSearchSupport.route(for: suggestion)
        router.request(routed.destination, targetFeature: routed.targetFeature)
    }

    /// The selected page can leave the sidebar when its last feature is
    /// switched off in the hub; fall back to the hub itself, where the
    /// feature can be brought back.
    private func ensureVisiblePage() {
        if !FeatureVisibilitySupport.isPageVisible(router.page, isAvailable: { $0.isAvailable }) {
            router.page = .features
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.page {
        case .general: GeneralSettings()
        case .features: FeatureHubSettings()
        case .textSnippets: TextSnippetsSettings()
        case .notch: NotchSettings()
        case .radialMenu: RadialMenuSettings()
        case .commandBar: CommandBarSettings()
        case .dictation: DictationSettings()
        case .energy: EnergySettings()
        case .monitor: MonitorSettings()
        case .mouse: MouseSettings()
        case .switcher: SwitcherSettings()
        case .keyDebounce: KeyboardDebounceSettings()
        case .superKey: SuperKeySettings()
        case .cutPaste: CutPasteSettings()
        case .autoQuit: AutoQuitSettings()
        case .quitProtection: QuitProtectionSettings()
        case .uninstaller: UninstallerView()
        case .killProcess: KillProcessView()
        case .urlCleaner: URLCleanerSettings()
        case .cleaner: CleanerSettings()
        case .homebrew: HomebrewSettings()
        case .appUpdates: AppUpdatesSettings()
        case .media: MediaSettings()
        case .clipboard: ClipboardSettings()
        case .quickTools: QuickToolsSettings()
        case .screenshot: ScreenCaptureSettings()
        case .windowLayout: WindowLayoutSettings()
        case .shelf: ShelfSettings()
        case .advanced: AdvancedSettings()
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var appearance = AppAppearanceController.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @AppStorage(DefaultsKey.hotkeyEnabled) private var hotkeyEnabled = true
    @AppStorage(DefaultsKey.musicBlockEnabled) private var musicBlockEnabled = false
    @AppStorage(DefaultsKey.musicBlockReplacementPath) private var musicBlockReplacementPath = ""

    private var appearanceStrings: AppearanceStrings { FeatureStrings.appearance(l10n.language) }
    private var feedbackStrings: FeedbackStrings { FeatureStrings.feedback(l10n.language) }

    var body: some View {
        Form {
            Section {
                Toggle(l10n.s.launchAtLogin, isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                    .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
                if let loginError {
                    Text(loginError)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                Picker(l10n.s.languageLabel, selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Picker(appearanceStrings.label, selection: $appearance.appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title(appearanceStrings)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
#if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    Toggle(appearanceStrings.liquidGlass, isOn: $appearance.liquidGlassEnabled)
                }
#endif
            }
            if AppFeature.keepAwake.isAvailable {
                Section(l10n.s.globalHotkeySection) {
                    SettingsToggleWithCaption(title: l10n.s.hotkeyToggle,
                                              caption: l10n.s.hotkeyCaption,
                                              isOn: $hotkeyEnabled)
                        .onChange(of: hotkeyEnabled) { _, enabled in
                            HotkeyManager.shared.setEnabled(enabled)
                        }
                    ShortcutPreferenceRow(role: .keepAwake, isEnabled: hotkeyEnabled) {
                        HotkeyManager.shared.syncWithPreferences()
                    }
                    if hotkeyEnabled, hotkeys.registrationFailed {
                        Text(l10n.s.shortcutUnavailable)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if AppFeature.musicBlock.isAvailable {
                Section(l10n.s.musicBlockSection) {
                    SettingsToggleWithCaption(title: l10n.s.musicBlockTitle,
                                              caption: l10n.s.musicBlockCaption,
                                              isOn: $musicBlockEnabled)
                        .onChange(of: musicBlockEnabled) { _, _ in
                            MusicLaunchBlocker.shared.syncWithPreferences()
                        }
                    if musicBlockEnabled {
                        HStack {
                            Text(l10n.s.musicBlockReplacementLabel)
                            Spacer()
                            Text(musicBlockReplacementName)
                                .foregroundStyle(.secondary)
                            Button(l10n.s.musicBlockChooseApp) { chooseMusicReplacement() }
                            if !musicBlockReplacementPath.isEmpty {
                                Button {
                                    musicBlockReplacementPath = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .settingsSectionAnchor(.musicBlocking)
            }
            if FeedbackService.isAvailable {
                Section(feedbackStrings.sectionTitle) {
                    Button {
                        appDelegate()?.openFeedbackWindow()
                    } label: {
                        Label(feedbackStrings.openButton,
                              systemImage: "bubble.left.and.text.bubble.right")
                    }
                    SettingsCaptionText(feedbackStrings.sectionCaption)
                }
            }
            // With no menu bar item there is no other place inside the app
            // to quit it from.
            Section {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label(l10n.s.menuQuit, systemImage: "power")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var musicBlockReplacementName: String {
        guard !musicBlockReplacementPath.isEmpty else { return l10n.s.musicBlockReplacementNone }
        let name = FileManager.default.displayName(atPath: musicBlockReplacementPath)
        return (name as NSString).deletingPathExtension
    }

    private func chooseMusicReplacement() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Picking the blocked app itself would start a launch-and-kill loop.
        if let bundleID = Bundle(url: url)?.bundleIdentifier,
           MusicLaunchBlocker.blockedBundleIDs.contains(bundleID) { return }
        musicBlockReplacementPath = url.path
    }
}

// MARK: - Energy

struct EnergySettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var awake = KeepAwakeManager.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var extraBrightness = ExtraBrightnessService.shared
    @ObservedObject private var brightness = BrightnessService.shared
    @AppStorage(DefaultsKey.brightnessControlEnabled) private var brightnessEnabled = false
    @AppStorage(DefaultsKey.brightnessKeysEnabled) private var brightnessKeysEnabled = false
    @AppStorage(DefaultsKey.brightnessOSDEnabled) private var brightnessOSDEnabled = false
    @AppStorage(DefaultsKey.extraBrightnessEnabled) private var extraBrightnessEnabled = false
    @AppStorage(DefaultsKey.extraBrightnessLevel) private var extraBrightnessLevel = 100
    @AppStorage(DefaultsKey.bluetoothSleepEnabled) private var bluetoothSleepEnabled = false
    @AppStorage(DefaultsKey.bluetoothSleepRestoreOnWake) private var bluetoothSleepRestoreOnWake = true
    @AppStorage(DefaultsKey.defaultDuration) private var defaultDuration = 0
    @AppStorage(DefaultsKey.batteryLimit) private var batteryLimit = 10
    @AppStorage(DefaultsKey.keepAwakeAutoStart) private var keepAwakeAutoStart = false
    @AppStorage(DefaultsKey.keepAwakeRightClickToggle) private var keepAwakeRightClickToggle = false
    @AppStorage(DefaultsKey.keepAwakeAllowDisplaySleep) private var keepAwakeAllowDisplaySleep = false
    @AppStorage(DefaultsKey.keepAwakePauseWhenLocked) private var keepAwakePauseWhenLocked = false
    @AppStorage(DefaultsKey.keepAwakeAutomationRequireAll) private var keepAwakeAutomationRequireAll = false
    @AppStorage(DefaultsKey.showCountdown) private var showCountdown = false
    @AppStorage(DefaultsKey.keepAwakeIconTint) private var keepAwakeIconTint = KeepAwakeIconTint.orange.rawValue
    @AppStorage(DefaultsKey.keepAwakeActiveIcon) private var keepAwakeActiveIcon = KeepAwakeActiveIcon.f4.rawValue
    @AppStorage(DefaultsKey.keepAwakeMouseJiggleEnabled) private var keepAwakeMouseJiggle = false
    @AppStorage(DefaultsKey.keepAwakeMouseJiggleInterval) private var keepAwakeMouseJiggleInterval = 5

    var body: some View {
        Form {
            if AppFeature.keepAwake.isAvailable {
                Section(l10n.s.keepAwakeTitle) {
                    Picker(l10n.s.defaultDurationLabel, selection: $defaultDuration) {
                        Text(l10n.s.minutes15).tag(15)
                        Text(l10n.s.minutes30).tag(30)
                        Text(l10n.s.hour1).tag(60)
                        Text(l10n.s.hours2).tag(120)
                        Text(l10n.s.hours4).tag(240)
                        Text(l10n.s.hours8).tag(480)
                        Text(l10n.s.indefinite).tag(0)
                    }
                    SettingsToggleWithCaption(title: l10n.s.keepAwakeAutoStart,
                                              caption: l10n.s.keepAwakeAutoStartCaption,
                                              isOn: $keepAwakeAutoStart)
                    SettingsToggleWithCaption(title: displaySleepStrings.allowDisplaySleep,
                                              caption: displaySleepStrings.allowDisplaySleepCaption,
                                              isOn: $keepAwakeAllowDisplaySleep)
                    SettingsToggleWithCaption(title: l10n.s.keepAwakeMouseJiggle,
                                              caption: l10n.s.keepAwakeMouseJiggleCaption,
                                              isOn: $keepAwakeMouseJiggle)
                    if keepAwakeMouseJiggle {
                        Picker(l10n.s.keepAwakeMouseJiggleInterval, selection: $keepAwakeMouseJiggleInterval) {
                            ForEach(Defaults.allowedKeepAwakeMouseJiggleIntervals, id: \.self) { minutes in
                                Text(KeepAwakeMouseJiggleIntervalPicker.label(for: minutes)).tag(minutes)
                            }
                        }
                        if !permissions.accessibility {
                            PermissionRow(kind: .accessibility)
                        }
                    }
                    SettingsMoreOptions {
                        // The countdown is a Keep Awake session readout, so it sits
                        // with the session options.
                        Toggle(l10n.s.showCountdown, isOn: $showCountdown)
                        SettingsToggleWithCaption(title: l10n.s.keepAwakeRightClickToggle,
                                                  caption: l10n.s.keepAwakeRightClickToggleCaption,
                                                  isOn: $keepAwakeRightClickToggle)
                        KeepAwakeIconPicker(iconValue: $keepAwakeActiveIcon,
                                            tintValue: $keepAwakeIconTint)
                    }
                }
                .settingsSectionAnchor(.keepAwake)
                Section {
                    KeepAwakeAutomationEditor()
                    SettingsToggleWithCaption(title: automationStrings.pauseWhenLockedToggle,
                                              caption: automationStrings.pauseWhenLockedCaption,
                                              isOn: $keepAwakePauseWhenLocked)
                } header: {
                    Text(automationStrings.automationSection)
                } footer: {
                    SettingsCaptionText(automationStrings.caption(requireAll: keepAwakeAutomationRequireAll))
                }
                if PowerSampler.hasInternalBattery {
                    Section(l10n.s.batteryProtectionSection) {
                        Picker(selection: $batteryLimit) {
                            Text(l10n.s.batteryNever).tag(0)
                            Text("5%").tag(5)
                            Text("10%").tag(10)
                            Text("15%").tag(15)
                            Text("20%").tag(20)
                        } label: {
                            SettingsLabel(l10n.s.batteryDisableBelow,
                                          caption: l10n.s.batteryProtectionCaption)
                        }
                    }
                }
                Section(l10n.s.clamshellSection) {
                    SettingsToggleWithCaption(title: l10n.s.clamshellTitle,
                                              caption: l10n.s.clamshellExplanation,
                                              isOn: $awake.clamshellPreferred)
                        .disabled(awake.clamshellSetupInProgress)
                    if awake.clamshellSetupInProgress {
                        Text(l10n.s.configuring)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if awake.clamshellSetupFailed {
                        Text(l10n.s.sudoersFailed)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            if AppFeature.brightness.isAvailable {
                let strings = FeatureStrings.brightness(l10n.language)
                Section(strings.pageTitle) {
                    SettingsToggleWithCaption(title: strings.enable,
                                              caption: strings.enableCaption,
                                              isOn: $brightnessEnabled)
                        .onChange(of: brightnessEnabled) { _, _ in
                            BrightnessService.shared.syncWithPreferences()
                        }
                    if brightnessEnabled {
                        if brightness.displays.isEmpty {
                            SettingsCaptionText(strings.noDisplays)
                        } else {
                            ForEach(brightness.displays) { display in
                                brightnessRow(display)
                            }
                        }
                        if let failure = brightness.displayControlFailure {
                            SettingsCaptionText(displayControlFailureText(failure, strings: strings))
                                .foregroundStyle(.red)
                        }
                        SettingsMoreOptions {
                            SettingsToggleWithCaption(title: strings.keysToggle,
                                                      caption: strings.keysCaption,
                                                      isOn: $brightnessKeysEnabled)
                                .onChange(of: brightnessKeysEnabled) { _, isOn in
                                    if isOn { Permissions.shared.requestAccessibility() }
                                    BrightnessService.shared.syncWithPreferences()
                                }
                            DisplayBrightnessShortcutControls()
                            if brightness.brightnessOSDSupported {
                                SettingsToggleWithCaption(title: strings.osdToggle,
                                                          caption: strings.osdCaption,
                                                          isOn: $brightnessOSDEnabled)
                                    .onChange(of: brightnessOSDEnabled) { _, isOn in
                                        if isOn { Permissions.shared.requestAccessibility() }
                                        BrightnessService.shared.syncWithPreferences()
                                    }
                            }
                            if (brightnessKeysEnabled || brightnessOSDEnabled),
                               !permissions.accessibility {
                                PermissionRow(kind: .accessibility)
                            }
                            SettingsCaptionText(strings.externalCaption)
                        }
                    }
                }
                .settingsSectionAnchor(.brightness)
            }
            if AppFeature.extraBrightness.isAvailable {
                Section(l10n.s.extraBrightnessName) {
                    if extraBrightness.supported {
                        SettingsDescribedToggle(title: l10n.s.extraBrightnessName,
                                                  caption: l10n.s.extraBrightnessCaption,
                                                  isOn: $extraBrightnessEnabled)
                            .onChange(of: extraBrightnessEnabled) { _, _ in
                                ExtraBrightnessService.shared.syncWithPreferences()
                            }
                        if extraBrightnessEnabled {
                            LabeledContent(l10n.s.extraBrightnessLevelLabel) {
                                HStack(spacing: 10) {
                                    Slider(value: extraBrightnessLevelBinding, in: 10...100, step: 5)
                                        .frame(maxWidth: 180)
                                    Text("\(extraBrightnessLevel)%")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                    } else {
                        SettingsCaptionText(l10n.s.extraBrightnessUnsupported)
                    }
                }
                .settingsSectionAnchor(.extraBrightness)
            }
            if AppFeature.bluetoothSleep.isAvailable {
                let strings = FeatureStrings.bluetoothSleep(l10n.language)
                Section(strings.pageTitle) {
                    if BluetoothSleepService.isSupported {
                        SettingsToggleWithCaption(title: strings.enable,
                                                  caption: strings.enableCaption,
                                                  isOn: $bluetoothSleepEnabled)
                            .onChange(of: bluetoothSleepEnabled) { _, _ in
                                BluetoothSleepService.shared.syncWithPreferences()
                            }
                        if bluetoothSleepEnabled {
                            SettingsToggleWithCaption(title: strings.restoreToggle,
                                                      caption: strings.restoreCaption,
                                                      isOn: $bluetoothSleepRestoreOnWake)
                        }
                    } else {
                        SettingsCaptionText(strings.unsupported)
                    }
                }
                .settingsSectionAnchor(.bluetoothSleep)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            defaultDuration = Defaults.sanitizedDefaultDuration(defaultDuration)
            batteryLimit = Defaults.sanitizedBatteryLimit(batteryLimit)
            keepAwakeIconTint = Defaults.sanitizedKeepAwakeIconTint(keepAwakeIconTint).rawValue
            keepAwakeActiveIcon = Defaults.sanitizedKeepAwakeActiveIcon(keepAwakeActiveIcon).rawValue
            keepAwakeMouseJiggleInterval = Defaults.sanitizedKeepAwakeMouseJiggleInterval(keepAwakeMouseJiggleInterval)
            awake.refreshPasswordlessStatus()
            // Displays may have changed since launch (docked, clamshell);
            // re-check so the section never shows a stale availability.
            ExtraBrightnessService.shared.syncWithPreferences()
            BrightnessService.shared.refresh()
        }
    }

    private func brightnessRow(_ display: BrightnessDisplay) -> some View {
        HStack(spacing: 10) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(display.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if display.isActive, display.method != nil {
                Slider(value: Binding(get: { display.brightness },
                                      set: { BrightnessService.shared.setBrightness(
                                          $0, for: display.id,
                                          showOSD: brightnessOSDEnabled) }),
                       in: 0...1)
                    .disabled(brightness.isDisplayPending(display.id))
                    .accessibilityLabel(display.name)
                Text("\(Int((display.brightness * 100).rounded()))%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Spacer()
                if !display.isActive {
                    Text(FeatureStrings.brightness(l10n.language).displayOff)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            DisplayPowerButton(display: display)
        }
    }

    private var extraBrightnessLevelBinding: Binding<Double> {
        Binding(get: { Double(extraBrightnessLevel) },
                set: { newValue in
                    extraBrightnessLevel = Int(newValue)
                    ExtraBrightnessService.shared.levelDidChange()
                })
    }

    private var automationStrings: KeepAwakeAutomationStrings {
        FeatureStrings.keepAwakeAutomation(l10n.language)
    }

    private var displaySleepStrings: KeepAwakeDisplaySleepStrings {
        FeatureStrings.keepAwakeDisplaySleep(l10n.language)
    }
}

// MARK: - Mouse

struct MouseSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var inverter = ScrollInverter.shared
    @ObservedObject private var smoothScroll = SmoothScrollService.shared
    @ObservedObject private var mouseNavigation = MouseNavigationService.shared
    @ObservedObject private var middleClick = MiddleClickService.shared
    @AppStorage(DefaultsKey.scrollInverterEnabled) private var invertVertical = false
    @AppStorage(DefaultsKey.scrollInverterHorizontalEnabled) private var invertHorizontal = false
    @AppStorage(DefaultsKey.scrollHorizontalEnabled) private var horizontalScrollEnabled = false
    @AppStorage(DefaultsKey.scrollHorizontalModifier) private var horizontalScrollModifier =
        ScrollHorizontalModifier.shift
    @AppStorage(DefaultsKey.focusFollowsMouseEnabled) private var focusFollowsMouseEnabled = false
    @AppStorage(DefaultsKey.focusFollowsMouseDelay) private var focusFollowsMouseDelay =
        FocusFollowsMouseSupport.defaultDelayMilliseconds
    @AppStorage(DefaultsKey.smoothScrollEnabled) private var smoothScrollEnabled = false
    @AppStorage(DefaultsKey.smoothScrollStep) private var smoothScrollStep = SmoothScrollSupport.defaultStep
    @AppStorage(DefaultsKey.mouseAccelerationDisabled) private var mouseAccelerationDisabled = false
    @AppStorage(DefaultsKey.smoothScrollResponse) private var smoothScrollResponse =
        SmoothScrollSupport.defaultResponse
    @AppStorage(DefaultsKey.mouseNavigationEnabled) private var mouseNavigationEnabled = false
    @AppStorage(DefaultsKey.mouseButtonShortcutsEnabled) private var mouseButtonShortcutsEnabled = false
    @AppStorage(DefaultsKey.mouseSpacesGestureEnabled) private var spacesEnabled = false
    @AppStorage(DefaultsKey.middleClickEnabled) private var middleClickEnabled = false
    @AppStorage(DefaultsKey.middleClickTapFingers) private var middleClickTapFingers = 0
    @AppStorage(DefaultsKey.mouseClickDebounceEnabled) private var mouseClickDebounceEnabled = false
    @AppStorage(DefaultsKey.mouseClickDebounceWindowMs) private var mouseClickDebounceWindow =
        Defaults.defaultMouseClickDebounceWindowMs

    private var mouseClickDebounceText: MouseClickDebounceStrings {
        FeatureStrings.mouseClickDebounce(l10n.language)
    }

    var body: some View {
        let modifierStrings = FeatureStrings.quitProtection(l10n.language)
        Form {
            if AppFeature.scrollInverter.isAvailable || AppFeature.scrollHorizontal.isAvailable {
                Section {
                    if AppFeature.scrollInverter.isAvailable {
                        Toggle(l10n.s.invertVerticalScroll, isOn: $invertVertical)
                            .onChange(of: invertVertical) { _, _ in
                                ScrollInverter.shared.syncWithPreferences()
                                if scrollDirectionEnabled { permissions.requestAccessibility() }
                            }
                        Toggle(l10n.s.invertHorizontalScroll, isOn: $invertHorizontal)
                            .onChange(of: invertHorizontal) { _, _ in
                                ScrollInverter.shared.syncWithPreferences()
                                if scrollDirectionEnabled { permissions.requestAccessibility() }
                            }
                    }
                    if AppFeature.scrollHorizontal.isAvailable {
                        SettingsToggleWithCaption(title: l10n.s.scrollHorizontalName,
                                                  caption: l10n.s.scrollHorizontalCaption,
                                                  isOn: $horizontalScrollEnabled)
                            .onChange(of: horizontalScrollEnabled) { _, _ in
                                ScrollInverter.shared.syncWithPreferences()
                                if scrollDirectionEnabled { permissions.requestAccessibility() }
                            }
                        if horizontalScrollEnabled {
                            Picker(l10n.s.scrollHorizontalModifierLabel, selection: $horizontalScrollModifier) {
                                Text("\(modifierStrings.shiftKey) (⇧)").tag(ScrollHorizontalModifier.shift)
                                Text("\(modifierStrings.optionKey) (⌥)").tag(ScrollHorizontalModifier.option)
                                Text("\(modifierStrings.controlKey) (⌃)").tag(ScrollHorizontalModifier.control)
                                Text("\(l10n.s.scrollHorizontalCommandKey) (⌘)").tag(ScrollHorizontalModifier.command)
                            }
                        }
                    }
                    if scrollInversionEnabled, inverter.isRunning {
                        Label(l10n.s.scrollActiveNow, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    if scrollDirectionEnabled {
                        MouseExceptionsList(scope: .scrollDirection)
                    }
                } header: {
                    Text(l10n.s.scrollSection)
                } footer: {
                    SettingsCaptionText(l10n.s.scrollTrackpadNote)
                }
                .settingsSectionAnchor(.scrollDirection)
            }
            if AppFeature.focusFollowsMouse.isAvailable {
                Section(l10n.s.focusFollowsMouseName) {
                    SettingsDescribedToggle(title: l10n.s.focusFollowsMouseName,
                                              caption: l10n.s.focusFollowsMouseCaption,
                                              isOn: $focusFollowsMouseEnabled)
                        .onChange(of: focusFollowsMouseEnabled) { _, enabled in
                            FocusFollowsMouseService.shared.syncWithPreferences()
                            if enabled { Permissions.shared.requestAccessibility() }
                        }
                    if focusFollowsMouseEnabled {
                        LabeledContent(l10n.s.focusFollowsMouseDelay) {
                            HStack(spacing: 10) {
                                Slider(value: focusFollowsMouseDelayBinding,
                                       in: Double(FocusFollowsMouseSupport.delayRange.lowerBound)
                                           ... Double(FocusFollowsMouseSupport.delayRange.upperBound),
                                       step: 50)
                                    .frame(maxWidth: 180)
                                    .accessibilityLabel(l10n.s.focusFollowsMouseDelay)
                                Text("\(focusFollowsMouseDelay) ms")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .trailing)
                            }
                        }
                        MouseExceptionsList(scope: .focusFollowsMouse)
                    }
                }
                .settingsSectionAnchor(.focusFollowsMouse)
            }
            if AppFeature.smoothScroll.isAvailable {
                Section(l10n.s.smoothScrollName) {
                    SettingsDescribedToggle(title: l10n.s.smoothScrollName,
                                              caption: l10n.s.smoothScrollCaption,
                                              isOn: $smoothScrollEnabled)
                        .onChange(of: smoothScrollEnabled) { _, enabled in
                            SmoothScrollService.shared.syncWithPreferences()
                            if enabled { permissions.requestAccessibility() }
                        }
                    if smoothScrollEnabled {
                        LabeledContent(l10n.s.smoothScrollStepLabel) {
                            HStack(spacing: 10) {
                                Slider(value: smoothScrollStepBinding,
                                       in: Double(SmoothScrollSupport.stepRange.lowerBound)...Double(SmoothScrollSupport.stepRange.upperBound),
                                       step: 10)
                                    .frame(maxWidth: 180)
                                    .accessibilityLabel(l10n.s.smoothScrollStepLabel)
                                Text("\(SmoothScrollSupport.sanitizedStep(smoothScrollStep))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                        MouseExceptionsList(scope: .smoothScroll)
                        SettingsMoreOptions {
                            LabeledContent(l10n.s.smoothScrollResponseLabel) {
                                HStack(spacing: 10) {
                                    Slider(value: smoothScrollResponseBinding,
                                           in: Double(SmoothScrollSupport.responseRange.lowerBound)
                                               ... Double(SmoothScrollSupport.responseRange.upperBound),
                                           step: 5)
                                        .frame(maxWidth: 180)
                                        .accessibilityLabel(l10n.s.smoothScrollResponseLabel)
                                    Text("\(SmoothScrollSupport.sanitizedResponse(smoothScrollResponse))%")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
                .settingsSectionAnchor(.smoothScroll)
            }
            if AppFeature.mouseAcceleration.isAvailable {
                Section(l10n.s.mouseAccelerationName) {
                    SettingsDescribedToggle(title: l10n.s.mouseAccelerationName,
                                              caption: l10n.s.mouseAccelerationCaption,
                                              isOn: $mouseAccelerationDisabled)
                        .onChange(of: mouseAccelerationDisabled) { _, _ in
                            MouseAccelerationService.shared.syncWithPreferences()
                        }
                }
                .settingsSectionAnchor(.mouseAcceleration)
            }
            if AppFeature.mouseNavigation.isAvailable {
                Section(l10n.s.mouseNavigationSection) {
                    SettingsToggleWithCaption(title: l10n.s.mouseNavigationEnable,
                                              caption: l10n.s.mouseNavigationCaption,
                                              isOn: $mouseNavigationEnabled)
                        .onChange(of: mouseNavigationEnabled) { _, enabled in
                            MouseNavigationService.shared.syncWithPreferences()
                            if enabled { permissions.requestAccessibility() }
                        }
                    if mouseNavigationEnabled, mouseNavigation.isRunning {
                        Label(l10n.s.mouseNavigationActiveNow, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    if mouseNavigationEnabled {
                        MouseExceptionsList(scope: .navigation)
                    }
                }
                .settingsSectionAnchor(.mouseNavigation)
            }
            if AppFeature.mouseButtonShortcuts.isAvailable {
                MouseButtonShortcutsSection()
            }
            if AppFeature.mouseClickDebounce.isAvailable {
                Section(mouseClickDebounceText.title) {
                    SettingsDescribedToggle(title: mouseClickDebounceText.title,
                                              caption: mouseClickDebounceText.caption,
                                              isOn: $mouseClickDebounceEnabled)
                        .onChange(of: mouseClickDebounceEnabled) { _, enabled in
                            MouseClickDebounceService.shared.syncWithPreferences()
                            if enabled { permissions.requestAccessibility() }
                        }
                    if mouseClickDebounceEnabled {
                        SettingsMoreOptions {
                            Stepper(value: mouseClickDebounceWindowBinding,
                                    in: Defaults.allowedMouseClickDebounceWindowRange,
                                    step: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    SettingsLabel(mouseClickDebounceText.windowLabel,
                                                  caption: mouseClickDebounceText.windowCaption)
                                    Text("\(Defaults.sanitizedMouseClickDebounceWindow(mouseClickDebounceWindow)) ms")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
                .settingsSectionAnchor(.mouseClickDebounce)
            }
            if AppFeature.middleClick.isAvailable {
                Section(l10n.s.middleClickSection) {
                    SettingsToggleWithCaption(title: l10n.s.middleClickEnable,
                                              caption: l10n.s.middleClickEnableCaption,
                                              isOn: $middleClickEnabled)
                        .onChange(of: middleClickEnabled) { _, enabled in
                            MiddleClickService.shared.syncWithPreferences()
                            if enabled { permissions.requestAccessibility() }
                        }
                    if middleClickEnabled {
                        Picker(selection: $middleClickTapFingers) {
                            Text(l10n.s.middleClickTapOff).tag(0)
                            Text(l10n.s.middleClickTapThreeFingers).tag(3)
                            Text(l10n.s.middleClickTapFourFingers).tag(4)
                        } label: {
                            SettingsLabel(l10n.s.middleClickTapPicker,
                                          caption: l10n.s.middleClickTapCaption)
                        }
                        .onChange(of: middleClickTapFingers) { _, _ in
                            MiddleClickService.shared.syncWithPreferences()
                        }
                    }
                    if middleClickEnabled, middleClick.systemDragGestureConflict {
                        Text(l10n.s.middleClickDragConflict)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if middleClickEnabled {
                        MouseExceptionsList(scope: .middleClick)
                    }
                }
                .settingsSectionAnchor(.middleClick)
            }
            if accessibilityNoteVisible {
                Section(l10n.s.permissionRequired) {
                    PermissionRow(kind: .accessibility)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            MiddleClickService.shared.refreshDragGestureConflict()
        }
    }

    /// Only features that are on AND still available can ask for the
    /// permission note; a hub-disabled one no longer needs anything.
    private var accessibilityNoteVisible: Bool {
        let anyEngaged = scrollDirectionEnabled
            || (focusFollowsMouseEnabled && AppFeature.focusFollowsMouse.isAvailable)
            || (smoothScrollEnabled && AppFeature.smoothScroll.isAvailable)
            || (mouseNavigationEnabled && AppFeature.mouseNavigation.isAvailable)
            || ((mouseButtonShortcutsEnabled || spacesEnabled)
                && AppFeature.mouseButtonShortcuts.isAvailable)
            || (mouseClickDebounceEnabled && AppFeature.mouseClickDebounce.isAvailable)
            || (middleClickEnabled && AppFeature.middleClick.isAvailable)
        return anyEngaged && !permissions.accessibility
    }

    private var scrollInversionEnabled: Bool {
        AppFeature.scrollInverter.isAvailable && (invertVertical || invertHorizontal)
    }

    private var scrollDirectionEnabled: Bool {
        scrollInversionEnabled
            || (AppFeature.scrollHorizontal.isAvailable && horizontalScrollEnabled)
    }

    private var smoothScrollStepBinding: Binding<Double> {
        Binding(
            get: { Double(SmoothScrollSupport.sanitizedStep(smoothScrollStep)) },
            set: { smoothScrollStep = Int($0) }
        )
    }

    private var smoothScrollResponseBinding: Binding<Double> {
        Binding(
            get: { Double(SmoothScrollSupport.sanitizedResponse(smoothScrollResponse)) },
            set: { smoothScrollResponse = Int($0) }
        )
    }

    private var focusFollowsMouseDelayBinding: Binding<Double> {
        Binding(
            get: { Double(FocusFollowsMouseSupport.sanitizedDelay(focusFollowsMouseDelay)) },
            set: {
                focusFollowsMouseDelay = Int($0)
                FocusFollowsMouseService.shared.preferencesDidChange()
            }
        )
    }

    private var mouseClickDebounceWindowBinding: Binding<Int> {
        Binding(
            get: { Defaults.sanitizedMouseClickDebounceWindow(mouseClickDebounceWindow) },
            set: {
                mouseClickDebounceWindow = Defaults.sanitizedMouseClickDebounceWindow($0)
                MouseClickDebounceService.shared.syncWithPreferences()
            }
        )
    }
}

// MARK: - Switcher

struct SwitcherSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var dockPreview = DockPreviewService.shared
    @AppStorage(DefaultsKey.switcherEnabled) private var switcherEnabled = true
    @AppStorage(DefaultsKey.switcherTakeOverSystemShortcuts) private var switcherTakeOverSystemShortcuts = false
    @AppStorage(DefaultsKey.switcherShortcut) private var switcherShortcutStorage = GlobalShortcut.switcherDefault.storageValue
    @AppStorage(DefaultsKey.switcherIconRowMode) private var switcherIconRowMode = false
    @AppStorage(DefaultsKey.switcherSimpleMode) private var switcherSimpleMode = false
    @AppStorage(DefaultsKey.switcherMergeTabs) private var switcherMergeTabs = false
    @AppStorage(DefaultsKey.switcherWindowlessApps) private var switcherWindowlessApps = SwitcherWindowlessApps.fallback.rawValue
    @AppStorage(DefaultsKey.switcherMinimizedPlacement) private var switcherMinimizedPlacement = WindowSwitchMinimizedPlacement.normal.rawValue
    @AppStorage(DefaultsKey.switcherShowFullscreenWindows) private var switcherShowFullscreenWindows = true
    @AppStorage(DefaultsKey.switcherScreenPlacement) private var switcherScreenPlacement = SwitcherScreenPlacement.fallback.rawValue
    @AppStorage(DefaultsKey.switcherCurrentDisplayOnly) private var switcherCurrentDisplayOnly = false
    @AppStorage(DefaultsKey.switcherCurrentSpaceOnly) private var switcherCurrentSpaceOnly = false
    @AppStorage(DefaultsKey.switcherSearchPinEnabled) private var switcherSearchPinEnabled = false
    @AppStorage(DefaultsKey.switcherShowShortcutHints) private var switcherShowShortcutHints = true
    @AppStorage(DefaultsKey.switcherAppearanceDelay) private var switcherAppearanceDelay = SwitcherSupport.defaultAppearanceDelayMilliseconds
    @AppStorage(DefaultsKey.dockPreviewEnabled) private var dockPreviewEnabled = false
    @AppStorage(DefaultsKey.dockPreviewCurrentSpaceOnly) private var dockPreviewCurrentSpaceOnly = false
    @AppStorage(DefaultsKey.dockPreviewBackgroundOpacity) private var dockPreviewBackgroundOpacity = 1.0
    @AppStorage(DefaultsKey.dockPreviewOpenDelay) private var dockPreviewOpenDelay = DockPreviewSupport.defaultOpenDelayMilliseconds
    @AppStorage(DefaultsKey.dockPreviewQuitAppOnClose) private var dockPreviewQuitAppOnClose = false
    @AppStorage(DefaultsKey.dockClickMinimize) private var dockClickMinimize = false
    @AppStorage(DefaultsKey.dockClickHide) private var dockClickHide = false
    @AppStorage(DefaultsKey.dockClickCycleWindows) private var dockClickCycleWindows = false
    @AppStorage(DefaultsKey.minimalWindowPreviews) private var minimalPreviews = false
    @AppStorage(DefaultsKey.previewSize) private var previewSize = "normal"

    private var layoutText: SettingsLayoutStrings { FeatureStrings.settingsLayout(l10n.language) }
    private var switcherEngaged: Bool { switcherEnabled && AppFeature.switcher.isAvailable }
    private var dockPreviewEngaged: Bool { dockPreviewEnabled && AppFeature.dockPreview.isAvailable }
    private var switcherShortcutDisplayString: String {
        (GlobalShortcut(storageValue: switcherShortcutStorage) ?? .switcherDefault).displayString
    }
    private var switcherWindowlessAppsSelection: Binding<String> {
        Binding(
            get: {
                SwitcherWindowlessApps.mode(
                    storedValue: switcherWindowlessApps,
                    takeOverSystemShortcuts: switcherTakeOverSystemShortcuts).rawValue
            },
            set: { value in
                if !switcherTakeOverSystemShortcuts { switcherWindowlessApps = value }
            }
        )
    }

    var body: some View {
        Form {
            if AppFeature.switcher.isAvailable {
                Section {
                    SettingsToggleWithCaption(title: l10n.s.switcherEnable,
                                              caption: l10n.s.switcherEnableCaption,
                                              isOn: $switcherEnabled)
                        .onChange(of: switcherEnabled) { _, _ in
                            AppSwitcher.shared.syncWithPreferences()
                        }
                    ShortcutPreferenceRow(role: .switcher,
                                          isEnabled: switcherEnabled,
                                          label: l10n.s.switcherShortcutHintApps) {
                        AppSwitcher.shared.syncWithPreferences()
                    }
                    ShortcutPreferenceRow(role: .switcherWindow,
                                          isEnabled: switcherEnabled,
                                          label: l10n.s.switcherShortcutHintWindows) {
                        AppSwitcher.shared.syncWithPreferences()
                    }
                } header: {
                    Text(l10n.s.switcherSection)
                } footer: {
                    SettingsCaptionText(String(format: l10n.s.switcherUsageHintFormat,
                                               GlobalShortcutRole.switcher.savedShortcut.displayString)
                                        + " " + l10n.s.switcherWindowShortcutCaption)
                }
                .settingsSectionAnchor(.switcher)

                Section(layoutText.behavior) {
                    SettingsToggleWithCaption(title: l10n.s.switcherTakeOverSystemShortcuts,
                                              caption: l10n.s.switcherTakeOverSystemShortcutsCaption,
                                              isOn: $switcherTakeOverSystemShortcuts)
                        .onChange(of: switcherTakeOverSystemShortcuts) { _, _ in
                            AppSwitcher.shared.syncWithPreferences()
                        }
                    SettingsToggleWithCaption(title: l10n.s.switcherSearchPin,
                                              caption: l10n.s.switcherSearchPinCaption,
                                              isOn: $switcherSearchPinEnabled)
                    LabeledContent {
                        HStack(spacing: 10) {
                            Slider(value: switcherAppearanceDelayBinding,
                                   in: Double(SwitcherSupport.appearanceDelayMillisecondsRange.lowerBound)
                                       ... Double(SwitcherSupport.appearanceDelayMillisecondsRange.upperBound),
                                   step: 25)
                                .frame(maxWidth: 180)
                            Text("\(sanitizedSwitcherAppearanceDelay) ms")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    } label: {
                        SettingsLabel(l10n.s.switcherAppearanceDelay,
                                      caption: l10n.s.switcherAppearanceDelayCaption)
                    }
                }
                .disabled(!switcherEnabled)

                Section(layoutText.appearance) {
                    SettingsToggleWithCaption(title: l10n.s.switcherSimpleMode,
                                              caption: l10n.s.switcherSimpleModeCaption,
                                              isOn: $switcherSimpleMode)
                        .onChange(of: switcherSimpleMode) { _, _ in
                            AppSwitcher.shared.syncWithPreferences()
                        }
                    SettingsToggleWithCaption(title: String(format: l10n.s.switcherIconRowMode,
                                                            switcherShortcutDisplayString),
                                              caption: l10n.s.switcherIconRowModeCaption,
                                              isOn: $switcherIconRowMode)
                        .disabled(switcherSimpleMode)
                        .onChange(of: switcherIconRowMode) { _, _ in
                            AppSwitcher.shared.syncWithPreferences()
                        }
                    if switcherSimpleMode || switcherIconRowMode {
                        SettingsToggleWithCaption(title: l10n.s.switcherShowShortcutHints,
                                                  caption: l10n.s.switcherShowShortcutHintsCaption,
                                                  isOn: $switcherShowShortcutHints)
                    }
                    SettingsToggleWithCaption(title: l10n.s.switcherMergeTabs,
                                              caption: l10n.s.switcherMergeTabsCaption,
                                              isOn: $switcherMergeTabs)
                }
                .disabled(!switcherEnabled)

                Section(layoutText.whatToShow) {
                    Picker(l10n.s.switcherMinimizedPlacementLabel, selection: $switcherMinimizedPlacement) {
                        Text(l10n.s.switcherMinimizedPlacementNormal).tag(WindowSwitchMinimizedPlacement.normal.rawValue)
                        Text(l10n.s.switcherMinimizedPlacementEnd).tag(WindowSwitchMinimizedPlacement.end.rawValue)
                        Text(l10n.s.switcherMinimizedPlacementHidden).tag(WindowSwitchMinimizedPlacement.hidden.rawValue)
                    }
                    .onChange(of: switcherMinimizedPlacement) { _, _ in
                        AppSwitcher.shared.syncWithPreferences()
                    }
                    Toggle(l10n.s.switcherShowFullscreenWindows, isOn: $switcherShowFullscreenWindows)
                        .onChange(of: switcherShowFullscreenWindows) { _, _ in
                            AppSwitcher.shared.syncWithPreferences()
                        }
                    Picker(selection: switcherWindowlessAppsSelection) {
                        Text(l10n.s.switcherWindowlessAppsOff).tag(SwitcherWindowlessApps.off.rawValue)
                        Text(l10n.s.switcherWindowlessAppsFinder).tag(SwitcherWindowlessApps.finder.rawValue)
                        Text(l10n.s.switcherWindowlessAppsAll).tag(SwitcherWindowlessApps.all.rawValue)
                    } label: {
                        SettingsLabel(l10n.s.switcherWindowlessApps,
                                      caption: l10n.s.switcherWindowlessAppsCaption)
                    }
                    .disabled(switcherTakeOverSystemShortcuts)
                    SettingsMoreOptions {
                        Picker(selection: $switcherScreenPlacement) {
                            Text(l10n.s.switcherScreenPlacementPointer).tag(SwitcherScreenPlacement.pointer.rawValue)
                            Text(l10n.s.switcherScreenPlacementMenuBar).tag(SwitcherScreenPlacement.menuBar.rawValue)
                            Text(l10n.s.switcherScreenPlacementActiveWindow).tag(SwitcherScreenPlacement.activeWindow.rawValue)
                        } label: {
                            SettingsLabel(l10n.s.switcherScreenPlacementLabel,
                                          caption: l10n.s.switcherScreenPlacementCaption)
                        }
                        SettingsToggleWithCaption(title: l10n.s.switcherCurrentDisplayOnly,
                                                  caption: l10n.s.switcherCurrentDisplayOnlyCaption,
                                                  isOn: $switcherCurrentDisplayOnly)
                        SettingsToggleWithCaption(title: l10n.s.switcherCurrentSpaceOnly,
                                                  caption: l10n.s.switcherCurrentSpaceOnlyCaption,
                                                  isOn: $switcherCurrentSpaceOnly)
                    }
                    SwitcherAppRulesList()
                }
                .disabled(!switcherEnabled)
            }
            if AppFeature.dockPreview.isAvailable {
                Section {
                    Toggle(isOn: $dockPreviewEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.s.dockPreviewEnable)
                            SettingsCaptionText(dockPreviewCaption)
                                .foregroundStyle(dockPreviewWarning ? .orange : .secondary)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: dockPreviewEnabled) { _, _ in
                        DockPreviewService.shared.syncWithPreferences()
                    }
                    if dockPreviewEnabled {
                        SettingsToggleWithCaption(title: l10n.s.switcherCurrentSpaceOnly,
                                                  caption: l10n.s.dockPreviewCurrentSpaceOnlyCaption,
                                                  isOn: $dockPreviewCurrentSpaceOnly)
                            .onChange(of: dockPreviewCurrentSpaceOnly) { _, _ in
                                DockPreviewService.shared.syncWithPreferences()
                            }
                        SettingsToggleWithCaption(title: l10n.s.dockPreviewQuitAppOnClose,
                                                  caption: l10n.s.dockPreviewQuitAppOnCloseCaption,
                                                  isOn: $dockPreviewQuitAppOnClose)
                        SettingsMoreOptions {
                            LabeledContent {
                                HStack(spacing: 6) {
                                    TextField("", value: dockPreviewOpenDelayBinding,
                                              formatter: Self.dockPreviewOpenDelayFormatter)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 64)
                                    Stepper("", value: dockPreviewOpenDelayBinding,
                                            in: DockPreviewSupport.openDelayMillisecondsRange,
                                            step: 50)
                                        .labelsHidden()
                                    Text(verbatim: "ms")
                                        .foregroundStyle(.secondary)
                                }
                            } label: {
                                SettingsLabel(l10n.s.dockPreviewOpenDelay,
                                              caption: l10n.s.dockPreviewOpenDelayCaption)
                            }
                            LabeledContent {
                                HStack(spacing: 10) {
                                    Slider(value: dockPreviewBackgroundOpacityBinding,
                                           in: DockPreviewSupport.backgroundOpacityRange,
                                           step: 0.05)
                                        .frame(maxWidth: 180)
                                    Text("\(dockPreviewBackgroundOpacityPercent)%")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .trailing)
                                }
                            } label: {
                                SettingsLabel(l10n.s.dockPreviewBackgroundOpacity,
                                              caption: l10n.s.dockPreviewBackgroundOpacityCaption)
                            }
                        }
                    }
                } header: {
                    Text(l10n.s.dockPreviewName)
                }
                .settingsSectionAnchor(.dock)
            }
            // Clicking a Dock icon is its own installable feature in the hub, so
            // it gets its own section here. It used to sit under the Dock Preview
            // header, which named one feature over the controls of two.
            if AppFeature.dockClick.isAvailable {
                Section {
                    SettingsToggleWithCaption(title: l10n.s.dockClickMinimize,
                                              caption: l10n.s.dockClickMinimizeCaption,
                                              isOn: $dockClickMinimize)
                        .onChange(of: dockClickMinimize) { _, enabled in
                            if enabled { dockClickHide = false }
                            DockClickService.shared.syncWithPreferences()
                        }
                    SettingsToggleWithCaption(title: l10n.s.dockClickHide,
                                              caption: l10n.s.dockClickHideCaption,
                                              isOn: $dockClickHide)
                        .onChange(of: dockClickHide) { _, enabled in
                            if enabled { dockClickMinimize = false }
                            DockClickService.shared.syncWithPreferences()
                        }
                    SettingsToggleWithCaption(title: l10n.s.dockClickCycleWindows,
                                              caption: l10n.s.dockClickCycleWindowsCaption,
                                              isOn: $dockClickCycleWindows)
                        .onChange(of: dockClickCycleWindows) { _, _ in
                            DockClickService.shared.syncWithPreferences()
                        }
                } header: {
                    Text(FeatureStrings.hub(l10n.language).titleDockClick)
                }
                .settingsSectionAnchor(.dockClick)
            }
            if AppFeature.switcher.isAvailable || AppFeature.dockPreview.isAvailable {
                Section {
                    Picker(l10n.s.previewSizeLabel, selection: $previewSize) {
                        Text(l10n.s.previewSizeSmall).tag("small")
                        Text(l10n.s.previewSizeNormal).tag("normal")
                        Text(l10n.s.previewSizeLarge).tag("large")
                        Text(l10n.s.previewSizeXLarge).tag("xlarge")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: previewSize) { _, _ in
                        AppSwitcher.shared.syncWithPreferences()
                    }
                    SettingsToggleWithCaption(title: l10n.s.minimalWindowPreviews,
                                              caption: l10n.s.minimalWindowPreviewsCaption,
                                              isOn: $minimalPreviews)
                    WindowPreviewExclusionsList()
                } header: {
                    Text(FeatureStrings.windowPreviewExclusions(l10n.language).sectionTitle)
                }
            }
            if switcherEngaged || dockPreviewEngaged {
                if !permissions.accessibility {
                    Section(l10n.s.permissionRequired) {
                        PermissionRow(kind: .accessibility)
                    }
                }
                if !permissions.screenRecording,
                   SwitcherSupport.needsScreenRecording(switcherEnabled: switcherEngaged,
                                                        simpleMode: switcherSimpleMode,
                                                        dockPreviewEnabled: dockPreviewEngaged) {
                    Section {
                        PermissionRow(kind: .screenRecording)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var dockPreviewCaption: String {
        guard dockPreviewEnabled else { return l10n.s.dockPreviewEnableCaption }
        if !permissions.accessibility { return "\(l10n.s.permissionRequired): \(l10n.s.permissionAccessibility)" }
        if !permissions.screenRecording { return "\(l10n.s.permissionRequired): \(l10n.s.permissionScreenRecording)" }
        switch dockPreview.blockedReason {
        case .dockUnavailable: return l10n.s.dockPreviewDockUnavailable
        default:
            return l10n.s.dockPreviewEnableCaption
        }
    }

    private var dockPreviewWarning: Bool {
        dockPreviewEnabled && dockPreview.blockedReason != nil
    }

    private var dockPreviewBackgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { DockPreviewSupport.sanitizedBackgroundOpacity(dockPreviewBackgroundOpacity) },
            set: { dockPreviewBackgroundOpacity = DockPreviewSupport.sanitizedBackgroundOpacity($0) }
        )
    }

    private var sanitizedSwitcherAppearanceDelay: Int {
        SwitcherSupport.sanitizedAppearanceDelay(milliseconds: switcherAppearanceDelay)
    }

    private var switcherAppearanceDelayBinding: Binding<Double> {
        Binding(
            get: { Double(sanitizedSwitcherAppearanceDelay) },
            set: {
                switcherAppearanceDelay = SwitcherSupport.sanitizedAppearanceDelay(
                    milliseconds: Int($0.rounded()))
            }
        )
    }

    private var dockPreviewBackgroundOpacityPercent: Int {
        Int((DockPreviewSupport.sanitizedBackgroundOpacity(dockPreviewBackgroundOpacity) * 100).rounded())
    }

    private var dockPreviewOpenDelayBinding: Binding<Int> {
        Binding(
            get: { DockPreviewSupport.sanitizedOpenDelay(milliseconds: dockPreviewOpenDelay) },
            set: { dockPreviewOpenDelay = DockPreviewSupport.sanitizedOpenDelay(milliseconds: $0) }
        )
    }

    /// Bounded here as well as in the binding: the field rejects an out-of-range
    /// number as it is typed rather than silently snapping it afterwards.
    private static let dockPreviewOpenDelayFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: DockPreviewSupport.openDelayMillisecondsRange.lowerBound)
        formatter.maximum = NSNumber(value: DockPreviewSupport.openDelayMillisecondsRange.upperBound)
        formatter.usesGroupingSeparator = false
        return formatter
    }()
}


// MARK: - Shared permission row

enum PermissionKind {
    case accessibility
    case screenRecording
    case microphone
}

/// Status + actions for one TCC permission; shared by Settings and onboarding.
struct PermissionRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @State private var pollingDemandID = UUID()
    let kind: PermissionKind

    private var granted: Bool {
        switch kind {
        case .accessibility: return permissions.accessibility
        case .screenRecording: return permissions.screenRecording
        case .microphone: return permissions.microphone == .granted
        }
    }

    private var monitorsActivePermission: Bool {
        switch kind {
        case .accessibility, .screenRecording: return true
        case .microphone: return false
        }
    }

    private var name: String {
        switch kind {
        case .accessibility: return l10n.s.permissionAccessibility
        case .screenRecording: return l10n.s.permissionScreenRecording
        case .microphone:
            return FeatureStrings.recorder(l10n.language).microphonePermissionName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(name)
                Spacer()
                Text(granted ? l10n.s.permissionGranted : l10n.s.permissionMissing)
                    .font(.subheadline)
                    .foregroundStyle(granted ? .green : .orange)
            }
            if !granted {
                HStack(spacing: 8) {
                    Button(l10n.s.permissionRequest) {
                        switch kind {
                        case .accessibility:
                            permissions.requestAccessibility()
                        case .screenRecording:
                            permissions.requestScreenRecording()
                        case .microphone:
                            permissions.requestMicrophone()
                        }
                    }
                    Button(l10n.s.permissionOpenSettings) {
                        switch kind {
                        case .accessibility:
                            permissions.openAccessibilitySettings()
                        case .screenRecording:
                            permissions.openScreenRecordingSettings()
                        case .microphone:
                            permissions.openMicrophoneSettings()
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            if monitorsActivePermission {
                permissions.setActivePermissionSurface(pollingDemandID, visible: true)
            }
        }
        .onDisappear {
            permissions.setActivePermissionSurface(pollingDemandID, visible: false)
        }
    }
}

/// Secure Event Input blocks every synthetic keystroke. Typing a snippet
/// trigger then does nothing at all, while the snippet library and the
/// Command Bar's typing actions beep; none of the four paths says what is
/// wrong or who is holding it. This row is the only place the app explains
/// that, and it names the holder when the session can attribute it.
///
/// Both call sites instantiate it only once secure input is on, and the
/// snippets page waits for one of its own toggles as well, so the `.off`
/// branch below is there to keep the switch exhaustive and for nothing else.
/// What drives the feature is the polling demand on each page; see
/// `SecureInputObservation`.
struct SecureInputRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var monitor = SecureInputMonitor.shared

    var body: some View {
        switch monitor.holder {
        case .off:
            EmptyView()
        case .app(let name, _):
            row(caption: String(format: l10n.s.secureInputHeldFormat, name)) {
                Button(String(format: l10n.s.secureInputRevealFormat, name)) {
                    monitor.revealHolder()
                }
                .controlSize(.small)
            }
        case .unattributed:
            row(caption: l10n.s.secureInputUnattributed) { EmptyView() }
        case .unknown:
            row(caption: l10n.s.secureInputUnidentified) { EmptyView() }
        }
    }

    private func row<Action: View>(caption: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(l10n.s.secureInputTitle)
                Spacer()
            }
            SettingsCaptionText(caption)
            action()
        }
    }
}

/// Keeps secure input polled for as long as the page is on screen and
/// `isActive` holds, e.g. the snippets page only while one of its own
/// toggles is on, since with both off nothing this row could report can
/// show. The demand cannot live on `SecureInputRow`: nothing would
/// register it until the state it reports had already been reached.
private struct SecureInputObservation: ViewModifier {
    let isActive: Bool
    @State private var demandID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { SecureInputMonitor.shared.setObservingSurface(demandID, visible: isActive) }
            .onDisappear { SecureInputMonitor.shared.setObservingSurface(demandID, visible: false) }
            .onChange(of: isActive) { _, active in
                SecureInputMonitor.shared.setObservingSurface(demandID, visible: active)
            }
    }
}

extension View {
    func observesSecureInput(isActive: Bool = true) -> some View {
        modifier(SecureInputObservation(isActive: isActive))
    }
}

/// Search field for the macOS 26 sidebar, styled after the system pill.
/// It sits on a fixed header outside the List, so scrolling rows can never
/// cross it (issues #183, #254). Esc and the clear button empty the query,
/// matching the system field.
private struct SidebarSearchField: View {
    @ObservedObject private var l10n = L10n.shared
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(l10n.s.settingsSearchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.s.urlCleanerClearButton)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private extension View {
    func searchResultRowStyle(isSelected: Bool) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            }
    }
}
