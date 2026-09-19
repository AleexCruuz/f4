// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Monitor" settings page: how often readings refresh, the temperature
/// unit, the memory measure and the alerts. Everything is reversible.
struct MonitorSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared

    @AppStorage(DefaultsKey.monitorInterval) private var interval = 2
    @AppStorage(DefaultsKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius.rawValue
    @AppStorage(DefaultsKey.monitorMemoryMetric) private var memoryMetric = "used"

    var body: some View {
        Form {
            Section {
                Picker(l10n.s.monitorIntervalLabel, selection: $interval) {
                    Text(l10n.s.monitorInterval1).tag(1)
                    Text(l10n.s.monitorInterval2).tag(2)
                    Text(l10n.s.monitorInterval5).tag(5)
                }
                Picker(l10n.s.temperatures, selection: $temperatureUnit) {
                    Text("°C").tag(TemperatureUnit.celsius.rawValue)
                    Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
                }
                .pickerStyle(.segmented)
                if AppFeature.monitorMemory.isAvailable {
                    Picker(l10n.s.monitorMemoryMetricLabel, selection: $memoryMetric) {
                        Text(l10n.s.memoryMetricUsed).tag("used")
                        Text(l10n.s.memoryMetricApp).tag("app")
                    }
                    .pickerStyle(.segmented)
                }
            }
            monitorAlertsSection
        }
        .formStyle(.grouped)
        .onAppear {
            interval = Defaults.sanitizedMonitorInterval(interval)
            if TemperatureUnit(rawValue: temperatureUnit) == nil {
                temperatureUnit = TemperatureUnit.celsius.rawValue
            }
            memoryMetric = Defaults.sanitizedMonitorMemoryMetric(memoryMetric)
        }
    }

    private var monitorAlertsSection: some View {
        let text = FeatureStrings.monitorAlerts(l10n.language)
        return Section {
            MonitorAlertsControls(compact: false)
        } header: {
            Text(text.section)
        } footer: {
            SettingsCaptionText(text.caption)
        }
    }
}
