// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct ShelfSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var shelf = ShelfService.shared
    @AppStorage(DefaultsKey.shelfEnabled) private var enabled = false
    @AppStorage(DefaultsKey.shelfShortcutEnabled) private var shortcutEnabled = true
    @AppStorage(DefaultsKey.shelfShakeToOpen) private var shake = true
    @AppStorage(DefaultsKey.shelfDropZoneEnabled) private var dropZone = true
    @AppStorage(DefaultsKey.shelfEdgeDragEnabled) private var edgeDrag = false
    @AppStorage(DefaultsKey.shelfCloseAfterDrop) private var closeAfterDrop = false
    @AppStorage(DefaultsKey.shelfRemoveAfterDrop) private var removeAfterDrop = true
    @AppStorage(DefaultsKey.shelfClearOnClose) private var clearOnClose = false
    @State private var showingAppPicker = false

    private var layoutText: SettingsLayoutStrings { FeatureStrings.settingsLayout(l10n.language) }

    var body: some View {
        Form {
            Section {
                SettingsToggleWithCaption(title: l10n.s.shelfEnable,
                                          caption: l10n.s.shelfEnableCaption,
                                          isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        ShelfService.shared.syncWithPreferences()
                    }
                if enabled {
                    Toggle(l10n.s.shelfShortcutToggle, isOn: $shortcutEnabled)
                        .onChange(of: shortcutEnabled) { _, _ in
                            ShelfService.shared.syncHotkey()
                        }
                    ShortcutPreferenceRow(role: .shelf, isEnabled: shortcutEnabled) {
                        ShelfService.shared.syncHotkey()
                    }
                    if shortcutEnabled, shelf.hotkeyRegistrationFailed {
                        Text(l10n.s.shortcutUnavailable)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        ShelfService.shared.summon()
                    } label: {
                        Label(l10n.s.shelfOpenNow, systemImage: "tray.and.arrow.down")
                    }
                }
            } footer: {
                SettingsCaptionText(l10n.s.shelfNoPermission)
            }

            Section(l10n.s.shelfHowTitle) {
                bullet("1", l10n.s.shelfStep1)
                bullet("2", l10n.s.shelfStep2)
                bullet("3", l10n.s.shelfStep3)
            }

            if enabled {
                Section(layoutText.behavior) {
                    SettingsToggleWithCaption(title: l10n.s.shelfShakeToggle,
                                              caption: l10n.s.shelfShakeCaption,
                                              isOn: $shake)
                        .onChange(of: shake) { _, _ in
                            ShelfService.shared.syncDragMonitor()
                        }
                    SettingsToggleWithCaption(title: l10n.s.shelfDropZoneToggle,
                                              caption: l10n.s.shelfDropZoneCaption,
                                              isOn: $dropZone)
                        .onChange(of: dropZone) { _, _ in
                            ShelfService.shared.syncDragMonitor()
                        }
                    SettingsToggleWithCaption(title: l10n.s.shelfEdgeToggle,
                                              caption: l10n.s.shelfEdgeCaption,
                                              isOn: $edgeDrag)
                        .onChange(of: edgeDrag) { _, _ in
                            ShelfService.shared.syncDragMonitor()
                        }
                }

                Section(l10n.s.shelfBehaviorTitle) {
                    SettingsToggleWithCaption(title: l10n.s.shelfCloseAfterDrop,
                                              caption: l10n.s.shelfCloseAfterDropCaption,
                                              isOn: $closeAfterDrop)
                    SettingsToggleWithCaption(title: l10n.s.shelfRemoveAfterDrop,
                                              caption: l10n.s.shelfRemoveAfterDropCaption,
                                              isOn: $removeAfterDrop)
                    SettingsToggleWithCaption(title: l10n.s.shelfClearOnClose,
                                              caption: l10n.s.shelfClearOnCloseCaption,
                                              isOn: $clearOnClose)
                }

                Section {
                    if sortedExclusions.isEmpty {
                        Text(l10n.s.shelfExclusionsEmpty)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedExclusions, id: \.self) { bundleID in
                            HStack(spacing: 9) {
                                Image(nsImage: InstalledApps.icon(for: bundleID))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text(InstalledApps.name(for: bundleID))
                                Spacer()
                                Button {
                                    shelf.removeAutomaticExclusion(bundleID)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button {
                        showingAppPicker = true
                    } label: {
                        Label(l10n.s.autoQuitAddApp, systemImage: "plus")
                    }
                } header: {
                    Text(l10n.s.shelfExclusionsTitle)
                } footer: {
                    SettingsCaptionText(l10n.s.shelfExclusionsCaption)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAppPicker) {
            appPickerSheet
        }
    }

    private var sortedExclusions: [String] {
        shelf.automaticExclusions.sorted {
            InstalledApps.name(for: $0)
                .localizedCaseInsensitiveCompare(InstalledApps.name(for: $1)) == .orderedAscending
        }
    }

    private var appPickerSheet: some View {
        let excluded = Set(shelf.automaticExclusions)
        return AppPickerView {
            showingAppPicker = false
        } onSelect: { url in
            showingAppPicker = false
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            shelf.addAutomaticExclusion(bundleID)
        } loadApps: {
            InstalledApps.installedBundleApplications(excluding: excluded)
        }
    }

    private func bullet(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
