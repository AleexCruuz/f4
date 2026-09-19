// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct CutPasteSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = FinderCutPaste.shared
    @AppStorage(DefaultsKey.finderCutPasteEnabled) private var enabled = false
    @AppStorage(DefaultsKey.finderCutPasteShowHUD) private var showHUD = true
    @AppStorage(DefaultsKey.finderRenameEnabled) private var renameEnabled = false
    @AppStorage(DefaultsKey.finderRenameShortcut) private var renameShortcutRaw =
        GlobalShortcut.finderRenameDefault.storageValue
    @State private var renameError: String?
    @State private var recordingRename = false

    private var renameText: FinderRenameFeatureStrings {
        FeatureStrings.finderRename(l10n.language)
    }

    private var renameShortcut: GlobalShortcut {
        GlobalShortcut(storageValue: renameShortcutRaw) ?? .finderRenameDefault
    }

    private var needsAccessibility: Bool {
        (AppFeature.finderCutPaste.isAvailable && enabled)
            || (AppFeature.finderRename.isAvailable && renameEnabled)
    }

    var body: some View {
        Form {
            if AppFeature.finderCutPaste.isAvailable {
                Section {
                    SettingsToggleWithCaption(title: l10n.s.cutPasteEnable,
                                              caption: l10n.s.cutPasteEnableCaption,
                                              isOn: $enabled)
                        .onChange(of: enabled) { _, _ in
                            FinderCutPaste.shared.syncWithPreferences()
                        }
                    if enabled {
                        SettingsToggleWithCaption(title: l10n.s.cutPasteShowHUD,
                                                  caption: l10n.s.cutPasteShowHUDCaption,
                                                  isOn: $showHUD)
                            .onChange(of: showHUD) { _, _ in
                                FinderCutPaste.shared.syncWithPreferences()
                            }
                    }
                    if enabled, service.isRunning {
                        Label(l10n.s.cutPasteActiveNow, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }
                .settingsSectionAnchor(.finderCutPaste)

                Section {
                    howRow(keys: ["⌘", "X"], text: l10n.s.cutPasteStep1)
                    howRow(keys: ["⌘", "V"], text: l10n.s.cutPasteStep2)
                } header: {
                    Text(l10n.s.cutPasteHowTitle)
                } footer: {
                    SettingsCaptionText(l10n.s.cutPasteTextNote)
                }
            }

            if AppFeature.finderRename.isAvailable {
                Section {
                    SettingsToggleWithCaption(title: renameText.enableLabel,
                                              caption: renameText.caption,
                                              isOn: $renameEnabled)
                        .onChange(of: renameEnabled) { _, _ in
                            FinderRenameService.shared.syncWithPreferences()
                        }
                    HStack(spacing: 8) {
                        Text(renameText.shortcutLabel)
                        Spacer()
                        ShortcutRecorderButton(
                            shortcut: renameShortcut,
                            isEnabled: renameEnabled,
                            waitingTitle: l10n.s.shortcutPressKeys,
                            notCapturedAction: { renameError = l10n.s.shortcutNotCaptured },
                            recordingChanged: { recording in
                                recordingRename = recording
                                if recording { renameError = nil }
                            },
                            invalidAction: { renameError = l10n.s.shortcutInvalid },
                            captureAction: saveRenameShortcut
                        )
                        .frame(width: 108)
                        .disabled(!renameEnabled)
                        if renameShortcut != .finderRenameDefault {
                            Button(l10n.s.shortcutReset) {
                                renameShortcutRaw = GlobalShortcut.finderRenameDefault.storageValue
                                renameError = nil
                                FinderRenameService.shared.syncWithPreferences()
                            }
                            .disabled(!renameEnabled)
                        }
                    }
                    if let renameError {
                        Text(renameError)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    } else if recordingRename {
                        Text(ShortcutRecordingCaption.text(l10n.s, canClear: false))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(renameText.hubTitle)
                }
                .settingsSectionAnchor(.finderRename)
            }

            if needsAccessibility, !permissions.accessibility {
                Section {
                    PermissionRow(kind: .accessibility)
                } header: {
                    Text(l10n.s.permissionRequired)
                } footer: {
                    if AppFeature.finderCutPaste.isAvailable, enabled {
                        SettingsCaptionText(l10n.s.cutPasteAutomationNote)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: l10n.language) { _, _ in renameError = nil }
    }

    private func howRow(keys: [String], text: String) -> some View {
        HStack(spacing: 10) {
            ShortcutCaps(keys: keys)
                .frame(width: 56, alignment: .leading)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveRenameShortcut(_ shortcut: GlobalShortcut) {
        if let conflict = GlobalShortcutRole.conflict(for: shortcut, excluding: .finderRename) {
            renameError = String(format: l10n.s.shortcutConflictFormat, conflict.title(l10n.s))
            return
        }
        if shortcut.conflictsWithSystemShortcut {
            renameError = String(format: l10n.s.shortcutConflictFormat, "macOS")
            return
        }
        if let conflict = WindowLayoutService.shared.shortcutConflictTitle(shortcut) {
            renameError = String(format: l10n.s.shortcutConflictFormat, conflict)
            return
        }
        renameShortcutRaw = shortcut.storageValue
        renameError = nil
        FinderRenameService.shared.syncWithPreferences()
    }
}
