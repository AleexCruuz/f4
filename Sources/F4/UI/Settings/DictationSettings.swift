// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import AppKit
import SwiftUI

struct DictationSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = DictationService.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.dictationEnabled) private var enabled = true
    @AppStorage(DefaultsKey.dictationLanguage) private var language = ""
    @AppStorage(DefaultsKey.dictationPolishMode) private var polishMode = DictationPolishMode.smart.rawValue
    @AppStorage(DefaultsKey.dictationVocabulary) private var vocabulary = ""
    @AppStorage(DefaultsKey.dictationModelPath) private var modelPath = DictationEngineSupport.defaultModelPath
    @AppStorage(DefaultsKey.dictationEndpoint) private var endpoint = DictationEngineSupport.defaultEndpoint

    private var text: DictationStrings { FeatureStrings.dictation(l10n.language) }
    private var layoutText: SettingsLayoutStrings { FeatureStrings.settingsLayout(l10n.language) }

    /// Where whisper.cpp publishes its converted models.
    private static let modelsURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/main")!

    var body: some View {
        Form {
            Section {
                SettingsToggleWithCaption(title: text.enableToggle,
                                          caption: text.settingsCaption,
                                          isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                ShortcutPreferenceRow(role: .dictation, isEnabled: enabled) {
                    service.syncWithPreferences()
                }
                if enabled, service.shortcutRegistrationFailed {
                    Text(l10n.s.shortcutUnavailable)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                if enabled, permissions.microphone != .granted {
                    PermissionRow(kind: .microphone)
                }
                if enabled, !permissions.accessibility {
                    PermissionRow(kind: .accessibility)
                }
            } header: {
                Text(text.pageTitle)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsCaptionText(text.fnHint)
                    SettingsCaptionText(text.privacyNote)
                }
            }

            Section {
                engineStatusRow
                HStack(spacing: 8) {
                    TextField(text.modelLabel, text: $modelPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button(text.chooseModel, action: chooseModel)
                }
                .onChange(of: modelPath) { _, _ in service.engineSettingsChanged() }
                Link(text.downloadModel, destination: Self.modelsURL)
                    .font(.subheadline)
                SettingsMoreOptions {
                    TextField(text.endpointLabel, text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: endpoint) { _, _ in service.engineSettingsChanged() }
                }
            } header: {
                Text(text.engineHeading)
            }
            .disabled(!enabled)

            Section(layoutText.behavior) {
                Picker(text.languageLabel, selection: $language) {
                    Text(text.languageSystem).tag("")
                    Text(text.languageAuto).tag("auto")
                    Divider()
                    ForEach(DictationLanguage.offered, id: \.self) { code in
                        Text(languageName(code)).tag(code)
                    }
                }
                Picker(selection: $polishMode) {
                    ForEach(DictationPolishMode.allCases) { mode in
                        Text(mode.title(l10n.language)).tag(mode.rawValue)
                    }
                } label: {
                    SettingsLabel(text.polishLabel, caption: text.polishCaption)
                }
                .pickerStyle(.segmented)
                TextField(text: $vocabulary,
                          prompt: Text(text.vocabularyPlaceholder), axis: .vertical) {
                    SettingsLabel(text.vocabularyLabel, caption: text.vocabularyCaption)
                }
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            }
            .disabled(!enabled)

            if !service.lastTranscript.isEmpty {
                Section {
                    Text(service.lastTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(text.copy) { service.copyLastTranscript() }
                        .controlSize(.small)
                } header: {
                    Text(text.lastDictation)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { service.engine.preflight() }
    }

    @ViewBuilder
    private var engineStatusRow: some View {
        HStack(spacing: 6) {
            switch service.engineState {
            case .ready(external: true):
                Label(String(format: text.engineExternal, endpoint), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .ready(external: false):
                Label(String(format: text.engineReady, modelFileName), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text(text.engineStarting)
            case .stopped:
                Label(text.engineStopped, systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            case let .failed(error):
                Label(error.message(l10n.language), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button(text.check) { service.checkEngine() }
                .controlSize(.small)
                .disabled(service.engineState == .starting)
        }
        .font(.subheadline)
    }

    private var modelFileName: String {
        (modelPath as NSString).lastPathComponent
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: Locale.current) ?? code
    }

    /// Stored with a tilde, so the setting survives a settings export to
    /// another Mac with a different home folder.
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: DictationEngineSupport.expandedPath(
            modelPath, home: FileManager.default.homeDirectoryForCurrentUser.path)).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelPath = (url.path as NSString).abbreviatingWithTildeInPath
    }
}
