// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct ClipboardSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var history = ClipboardHistoryService.shared
    @ObservedObject private var pastePlain = PastePlainService.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.pastePlainEnabled) private var pastePlainEnabled = false
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var enabled = false
    @AppStorage(DefaultsKey.clipboardHistoryLimit) private var limit = 50
    @AppStorage(DefaultsKey.clipboardHistorySkipSensitive) private var skipSensitive = true
    @AppStorage(DefaultsKey.clipboardHistoryIncludeImagesFiles) private var includeImagesFiles = true
    @AppStorage(DefaultsKey.clipboardHistoryShortcutEnabled) private var shortcutEnabled = true
    @AppStorage(DefaultsKey.finderPasteImageAsFile) private var pasteImageAsFile = false
    @AppStorage(DefaultsKey.clipboardAutoClearOnDelay) private var autoClearOnDelay = false
    @AppStorage(DefaultsKey.clipboardAutoClearDelay)
    private var autoClearDelay = Defaults.defaultClipboardAutoClearDelay
    @AppStorage(DefaultsKey.clipboardAutoClearOnSleep) private var autoClearOnSleep = false
    @AppStorage(DefaultsKey.clipboardAutoClearOnDisplaySleep) private var autoClearOnDisplaySleep = false
    @AppStorage(DefaultsKey.clipboardAutoClearOnScreenLock) private var autoClearOnScreenLock = false
    @ObservedObject private var clipboardAI = ClipboardAIService.shared
    @AppStorage(DefaultsKey.clipboardAIEnabled) private var aiEnabled = false
    @AppStorage(DefaultsKey.clipboardAIModel) private var aiModel = Defaults.defaultClipboardAIModel
    @AppStorage(DefaultsKey.clipboardAIEndpoint)
    private var aiEndpoint = Defaults.defaultClipboardAIEndpoint
    @AppStorage(DefaultsKey.clipboardAITargetLanguage) private var aiTargetLanguage = ""
    @AppStorage(DefaultsKey.clipboardAIBlockSensitive) private var aiBlockSensitive = true

    private var text: ClipboardFeatureStrings {
        FeatureStrings.clipboard(l10n.language)
    }

    private var layoutText: SettingsLayoutStrings { FeatureStrings.settingsLayout(l10n.language) }

    var body: some View {
        Form {
            if AppFeature.clipboardHistory.isAvailable {
                Section {
                    SettingsToggleWithCaption(title: text.enable,
                                              caption: text.caption,
                                              isOn: $enabled)
                        .onChange(of: enabled) { _, _ in
                            ClipboardHistoryService.shared.syncWithPreferences()
                        }
                    if enabled, history.isRunning {
                        Label(text.active, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                } footer: {
                    SettingsCaptionText(text.localNote)
                }
                .settingsSectionAnchor(.clipboardHistory)

                clipboardShortcutSection

                Section(layoutText.behavior) {
                    SettingsToggleWithCaption(title: text.includeImagesFiles,
                                              caption: text.includeImagesFilesCaption,
                                              isOn: $includeImagesFiles)
                        .disabled(!enabled)
                    SettingsToggleWithCaption(title: text.skipSensitive,
                                              caption: text.skipSensitiveCaption,
                                              isOn: $skipSensitive)
                        .disabled(!enabled)
                    ClipboardIgnoredAppsList()
                        .disabled(!enabled)
                    Picker(text.limit, selection: $limit) {
                        ForEach(Defaults.allowedClipboardHistoryLimits, id: \.self) { value in
                            Text(value == 0 ? text.limitUnlimited : "\(value)").tag(value)
                        }
                    }
                    .disabled(!enabled)
                    clipboardStatsRow
                }

                clipboardAutoClearSection
                clipboardAISection
            }

            if AppFeature.finderCutPaste.isAvailable {
                Section {
                    SettingsToggleWithCaption(title: text.pasteImageAsFile,
                                              caption: text.pasteImageAsFileCaption,
                                              isOn: $pasteImageAsFile)
                        .onChange(of: pasteImageAsFile) { _, _ in
                            FinderCutPaste.shared.syncWithPreferences()
                        }
                    if pasteImageAsFile, !permissions.accessibility {
                        PermissionRow(kind: .accessibility)
                    }
                } header: {
                    Text(l10n.s.cutPasteName)
                }
            }

            if AppFeature.pastePlain.isAvailable {
                Section {
                    SettingsDescribedToggle(title: l10n.s.pastePlainName,
                                              caption: l10n.s.pastePlainCaption,
                                              isOn: $pastePlainEnabled)
                        .onChange(of: pastePlainEnabled) { _, _ in
                            PastePlainService.shared.syncWithPreferences()
                        }
                    ShortcutPreferenceRow(role: .pastePlain,
                                          isEnabled: pastePlainEnabled) {
                        PastePlainService.shared.syncWithPreferences()
                    }
                    if pastePlainEnabled, pastePlain.shortcutRegistrationFailed {
                        Text(l10n.s.shortcutUnavailable)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if pastePlainEnabled, !permissions.accessibility {
                        PermissionRow(kind: .accessibility)
                    }
                } header: {
                    Text(l10n.s.pastePlainName)
                }
                .settingsSectionAnchor(.pastePlain)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            limit = Defaults.sanitizedClipboardHistoryLimit(limit)
            autoClearDelay = Defaults.sanitizedClipboardAutoClearDelay(autoClearDelay)
        }
        .onChange(of: limit) { _, value in
            let sanitized = Defaults.sanitizedClipboardHistoryLimit(value)
            if sanitized != value { limit = sanitized }
            ClipboardHistoryService.shared.trimToLimit()
        }
        // No syncWithPreferences() here, unlike the auto-clear toggles: the
        // running poll reads this value from UserDefaults on every tick, so a
        // new delay takes effect on the next one. Syncing would just tear the
        // timer down and restart the wait.
        .onChange(of: autoClearDelay) { _, value in
            let sanitized = Defaults.sanitizedClipboardAutoClearDelay(value)
            if sanitized != value { autoClearDelay = sanitized }
        }
    }

    @ViewBuilder
    private var clipboardShortcutSection: some View {
        Section {
            Toggle(text.shortcut, isOn: $shortcutEnabled)
                .onChange(of: shortcutEnabled) { _, _ in
                    ClipboardHistoryService.shared.syncHotkey()
                }
                .disabled(!enabled)
            ShortcutPreferenceRow(role: .clipboard,
                                  isEnabled: enabled && shortcutEnabled,
                                  additionalConflict: WindowLayoutService.shared.shortcutConflictTitle) {
                ClipboardHistoryService.shared.syncHotkey()
            }
            if enabled, shortcutEnabled, history.shortcutRegistrationFailed {
                Text(l10n.s.shortcutUnavailable)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Button {
                ClipboardHistoryService.shared.showHistoryWindow()
            } label: {
                Label(text.shortcut, systemImage: "doc.on.clipboard")
            }
            .disabled(history.entries.isEmpty)
        } header: {
            Text(layoutText.shortcuts)
        } footer: {
            SettingsCaptionText(text.shortcutCaption)
        }
    }

    // Needs saved entries to act on, so it follows the capture toggle. The
    // runner is the user's own install and may not be there at all, which is
    // the normal first-run state rather than an error — the status row says so
    // and names the command that fixes it.
    @ViewBuilder
    private var clipboardAISection: some View {
        let aiText = FeatureStrings.clipboardAI(l10n.language)
        Section {
            SettingsToggleWithCaption(title: aiText.settingsEnable,
                                      caption: aiText.settingsCaption,
                                      isOn: $aiEnabled)
                .disabled(!enabled)
                .onChange(of: aiEnabled) { _, isOn in
                    guard isOn else { return }
                    Task {
                        await clipboardAI.refreshInstalledModels()
                        // Paying the ~35 s model load now, while the user is
                        // still in settings, means the first real action is
                        // the warm ~2 s one.
                        clipboardAI.warmUp()
                    }
                }

            if aiEnabled {
                SettingsToggleWithCaption(title: aiText.settingsBlockSensitive,
                                          caption: aiText.settingsBlockSensitiveCaption,
                                          isOn: $aiBlockSensitive)
                TextField(aiText.settingsModel, text: $aiModel)
                    .textFieldStyle(.roundedBorder)
                TextField(aiText.settingsTargetLanguage, text: $aiTargetLanguage,
                          prompt: Text(aiText.settingsTargetLanguagePlaceholder))
                    .textFieldStyle(.roundedBorder)

                clipboardAIStatusRow

                SettingsMoreOptions {
                    TextField(aiText.settingsEndpoint, text: $aiEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
        } header: {
            Text(aiText.title)
        } footer: {
            SettingsCaptionText(aiText.settingsLocalNote)
        }
        .disabled(!AppFeature.clipboardHistory.isAvailable)
    }

    @ViewBuilder
    private var clipboardAIStatusRow: some View {
        let aiText = FeatureStrings.clipboardAI(l10n.language)
        HStack(spacing: 6) {
            switch clipboardAI.installedModels {
            case .none:
                Label(aiText.statusNoRunner, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            case let .some(models) where models.contains(clipboardAI.model):
                Label(String(format: aiText.statusReady, clipboardAI.model),
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            case .some:
                Label(String(format: aiText.statusModelNotInstalled, clipboardAI.model),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button(aiText.check) {
                Task { await clipboardAI.refreshInstalledModels() }
            }
            .controlSize(.small)
        }
        .task {
            // Probe once when the pane appears so the row is never blank.
            await clipboardAI.refreshInstalledModels()
        }
    }

    // Never disabled by the capture toggle, unlike the sections above it:
    // emptying the pasteboard is a security setting in its own right, and
    // someone who keeps no history is exactly who reaches for it.
    @ViewBuilder
    private var clipboardAutoClearSection: some View {
        Section {
            HStack {
                Toggle(text.autoClearEnable, isOn: $autoClearOnDelay)
                    .onChange(of: autoClearOnDelay) { _, _ in
                        ClipboardAutoClearService.shared.syncWithPreferences()
                    }
                TextField("", value: $autoClearDelay, formatter: Self.delayFieldFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .disabled(!autoClearOnDelay)
                Text(text.autoClearSecondsSuffix)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Toggle(text.autoClearOnSleep, isOn: $autoClearOnSleep)
                .onChange(of: autoClearOnSleep) { _, _ in
                    ClipboardAutoClearService.shared.syncWithPreferences()
                }
            Toggle(text.autoClearOnDisplaySleep, isOn: $autoClearOnDisplaySleep)
                .onChange(of: autoClearOnDisplaySleep) { _, _ in
                    ClipboardAutoClearService.shared.syncWithPreferences()
                }
            Toggle(text.autoClearOnScreenLock, isOn: $autoClearOnScreenLock)
                .onChange(of: autoClearOnScreenLock) { _, _ in
                    ClipboardAutoClearService.shared.syncWithPreferences()
                }
        } header: {
            Text(layoutText.privacy)
        } footer: {
            SettingsCaptionText(text.autoClearCaption)
        }
    }

    private static let delayFieldFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: Defaults.allowedClipboardAutoClearDelayRange.lowerBound)
        formatter.maximum = NSNumber(value: Defaults.allowedClipboardAutoClearDelayRange.upperBound)
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    private var clipboardStatsRow: some View {
        HStack {
            Text("\(history.pinnedEntries.count)")
            Text(text.pinned)
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(history.recentEntries.count)")
            Text(text.recent)
                .foregroundStyle(.secondary)
            Spacer()
            Button(text.clearRecent) {
                history.clearRecent()
            }
            .disabled(history.recentEntries.isEmpty)
            Button(text.clearAll) {
                history.clearAll()
            }
            .disabled(history.recentEntries.isEmpty)
        }
    }
}
