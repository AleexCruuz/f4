// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct AutoQuitSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = AutoQuitService.shared
    @AppStorage(DefaultsKey.autoQuitEnabled) private var enabled = false
    @State private var showingAppPicker = false

    var body: some View {
        Form {
            Section {
                SettingsToggleWithCaption(title: l10n.s.autoQuitEnable,
                                          caption: l10n.s.autoQuitEnableCaption,
                                          isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        AutoQuitService.shared.syncWithPreferences()
                    }
                if enabled, service.isRunning {
                    Label(l10n.s.autoQuitActiveNow, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }

            Section {
                bullet("rectangle.badge.xmark", l10n.s.autoQuitStep1)
                bullet("bolt.fill", l10n.s.autoQuitStep2)
            } header: {
                Text(l10n.s.autoQuitHowTitle)
            } footer: {
                SettingsCaptionText(l10n.s.autoQuitPredictableNote)
            }

            // The exception list has one reader, the window check, and that only
            // runs while the feature does. With the switch off every edit here
            // is a no-op, so the list follows it.
            Section {
                if sortedExceptions.isEmpty {
                    Text(l10n.s.autoQuitExceptionsEmpty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedExceptions, id: \.self) { bundleID in
                        HStack(spacing: 9) {
                            Image(nsImage: InstalledApps.icon(for: bundleID))
                                .resizable().frame(width: 20, height: 20)
                            Text(InstalledApps.name(for: bundleID))
                            Spacer()
                            if service.isMandatoryException(bundleID) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.tertiary)
                            } else {
                                Button {
                                    service.removeException(bundleID)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .disabled(!enabled)
                }

                Button {
                    showingAppPicker = true
                } label: {
                    Label(l10n.s.autoQuitAddApp, systemImage: "plus")
                }
                .disabled(!enabled)
            } header: {
                Text(l10n.s.autoQuitExceptionsTitle)
            } footer: {
                SettingsCaptionText(l10n.s.autoQuitExceptionsCaption)
            }

            if enabled, !permissions.accessibility {
                Section(l10n.s.permissionRequired) {
                    PermissionRow(kind: .accessibility)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAppPicker) {
            appPickerSheet
        }
    }

    private var sortedExceptions: [String] {
        AutoQuitSupport.visibleExceptions(service.exceptions) {
            InstalledApps.url(for: $0) != nil
        }
        .sorted {
            InstalledApps.name(for: $0).localizedCaseInsensitiveCompare(InstalledApps.name(for: $1))
                == .orderedAscending
        }
    }

    private var appPickerSheet: some View {
        let excluded = Set(service.exceptions)
        return AppPickerView {
            showingAppPicker = false
        } onSelect: { url in
            showingAppPicker = false
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            service.addException(bundleID)
        } loadApps: {
            InstalledApps.installedBundleApplications(excluding: excluded)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
