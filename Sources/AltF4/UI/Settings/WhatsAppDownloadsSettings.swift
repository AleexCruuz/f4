// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct WhatsAppDownloadsSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var manager = WhatsAppDownloadManager.shared
    @ObservedObject private var scheduler = WhatsAppDownloadScheduler.shared
    @ObservedObject private var organizer = WhatsAppDownloadOrganizer.shared
    @ObservedObject private var permissions = Permissions.shared

    @AppStorage(DefaultsKey.whatsAppDownloadsEnabled) private var enabled = false
    @AppStorage(DefaultsKey.whatsAppDownloadsAutomaticEnabled) private var automatic = false
    @AppStorage(DefaultsKey.whatsAppDownloadsCategories) private var categoriesRaw = "image,video,audio"
    @AppStorage(DefaultsKey.whatsAppDownloadsRetentionDays) private var retentionDays = 7
    @AppStorage(DefaultsKey.whatsAppDownloadsNotify) private var notify = true
    @AppStorage(DefaultsKey.whatsAppDownloadsLastCleanup) private var lastCleanup = 0.0
    @AppStorage(DefaultsKey.whatsAppDownloadsLastCleanupCount) private var lastCount = 0
    @AppStorage(DefaultsKey.whatsAppDownloadsLastCleanupBytes) private var lastBytes = 0
    @AppStorage(DefaultsKey.whatsAppDownloadsLastCleanupFailed) private var lastFailed = 0
    @AppStorage(DefaultsKey.whatsAppOrganizerEnabled) private var organizerEnabled = false
    @AppStorage(DefaultsKey.whatsAppOrganizerDestinationPath) private var organizerDestination = ""
    @AppStorage(DefaultsKey.whatsAppOrganizerDelayMinutes) private var organizerDelay = 5
    @AppStorage(DefaultsKey.whatsAppOrganizerCategories) private var organizerCategoriesRaw = "image,video,audio,document,archive,other"
    @AppStorage(DefaultsKey.whatsAppOrganizerLayout) private var organizerLayout = "flat"
    @AppStorage(DefaultsKey.whatsAppOrganizerDuplicateAction) private var duplicateAction = "trashNew"
    @AppStorage(DefaultsKey.whatsAppOrganizerLastRun) private var organizerLastRun = 0.0
    @AppStorage(DefaultsKey.whatsAppOrganizerLastMoved) private var organizerLastMoved = 0
    @AppStorage(DefaultsKey.whatsAppOrganizerLastDuplicates) private var organizerLastDuplicates = 0
    @AppStorage(DefaultsKey.whatsAppOrganizerLastFailed) private var organizerLastFailed = 0

    @State private var waitingToEnable = false
    @State private var showingExistingChoice = false
    @State private var showingInvalidDestination = false
    @State private var showingOrganizerFileTypes = false

    private var text: WhatsAppDownloadStrings {
        FeatureStrings.whatsAppDownloads(l10n.language)
    }

    private var organizerText: WhatsAppOrganizerStrings {
        WhatsAppOrganizerStrings.localized(l10n.language)
    }

    private var layoutText: SettingsLayoutStrings { FeatureStrings.settingsLayout(l10n.language) }

    var body: some View {
        Form {
            introductionSection
            automationSection
            typesSection
            organizerSection
            organizerOptionsSection
            manualSection
            activitySection
        }
        .formStyle(.grouped)
        .onAppear {
            manager.setReviewVisible(true)
            retentionDays = WhatsAppDownloadSupport.sanitizedRetentionDays(retentionDays)
            organizerDelay = WhatsAppDownloadSupport.sanitizedOrganizerDelayMinutes(organizerDelay)
            if manager.phase == .idle { manager.scan() }
        }
        .onDisappear { manager.setReviewVisible(false) }
        .onChange(of: manager.phase) { _, phase in
            if automatic, phase == .results || phase == .failed {
                WhatsAppDownloadScheduler.shared.syncWithPreferences()
            }
            if organizerEnabled, phase == .results || phase == .failed {
                WhatsAppDownloadOrganizer.shared.syncWithPreferences()
            }
            guard waitingToEnable else { return }
            switch phase {
            case .results:
                waitingToEnable = false
                if manager.eligibleCount > 0 {
                    showingExistingChoice = true
                } else {
                    enableAutomation(includeExisting: false)
                }
            case .failed:
                waitingToEnable = false
            default:
                break
            }
        }
        .alert(text.firstTitle, isPresented: $showingExistingChoice) {
            Button(text.futureOnly) { enableAutomation(includeExisting: false) }
            Button(text.includeExisting) { enableAutomation(includeExisting: true) }
            Button(FeatureStrings.hub(l10n.language).presetConfirmCancel, role: .cancel) {}
        } message: {
            Text(String(format: text.firstMessageFormat, manager.eligibleCount))
        }
        .alert(organizerText.invalidDestination, isPresented: $showingInvalidDestination) {
            Button("OK", role: .cancel) {}
        }
    }

    private var introductionSection: some View {
        Section {
            SettingsToggleWithCaption(title: text.title,
                                      caption: text.intro,
                                      isOn: $enabled)
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(text.folder)
                    Text(manager.downloadsURL?.path.replacingOccurrences(
                        of: NSHomeDirectory(), with: "~") ?? "~/Downloads")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.s.cleanerRevealInFinder) {
                    if let url = manager.downloadsURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            accessRow
        }
    }

    @ViewBuilder
    private var accessRow: some View {
        switch manager.accessStatus {
        case .available:
            Label(text.accessReady, systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .denied:
            HStack(alignment: .firstTextBaseline) {
                Label(text.accessDenied, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Spacer()
                Button(FeatureStrings.hub(l10n.language).openSystemSettings) {
                    permissions.openFilesAndFoldersSettings()
                }
                .controlSize(.small)
            }
        case .unknown:
            EmptyView()
        }
    }

    private var automationSection: some View {
        Section {
            SettingsToggleWithCaption(title: text.automatic,
                                      caption: text.automaticCaption,
                                      isOn: automaticBinding)
            Picker(selection: $retentionDays) {
                ForEach(WhatsAppDownloadSupport.allowedRetentionDays, id: \.self) { days in
                    Text(String(format: text.daysFormat, days)).tag(days)
                }
            } label: {
                SettingsLabel(text.retention, caption: text.retentionCaption)
            }
            .onChange(of: retentionDays) { _, value in
                retentionDays = WhatsAppDownloadSupport.sanitizedRetentionDays(value)
                refreshResultsIfVisible()
            }
            Toggle(l10n.s.cleanerScheduleNotifyToggle, isOn: $notify)
                .onChange(of: notify) { _, enabled in
                    if enabled { Notifier.requestPermission() }
                }
            if notify, permissions.notifications == .denied {
                HStack {
                    Text(l10n.s.cleanerNotifDenied)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(l10n.s.cleanerNotifOpenSettings) {
                        permissions.openNotificationSettings()
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text(l10n.s.cleanerScheduleTitle)
        }
    }

    private var automaticBinding: Binding<Bool> {
        Binding(
            get: { automatic },
            set: { enabled in
                if enabled {
                    waitingToEnable = true
                    manager.scan()
                } else {
                    automatic = false
                    WhatsAppDownloadScheduler.shared.syncWithPreferences()
                }
            }
        )
    }

    private var typesSection: some View {
        Section(text.fileTypes) {
            Toggle(text.allTypes, isOn: allCategoriesBinding)
                .toggleStyle(.checkbox)
            categoryPair(.image, .video)
            categoryPair(.audio, .document)
            categoryPair(.archive, .other)
        }
    }

    private var organizerSection: some View {
        Section {
            SettingsToggleWithCaption(title: organizerText.enabled,
                                      caption: organizerText.description,
                                      isOn: $organizerEnabled)
                .onChange(of: organizerEnabled) { _, enabled in
                    if enabled {
                        manager.scan()
                        if notify { Notifier.requestPermission() }
                    }
                    organizer.syncWithPreferences()
                }
                .disabled(organizer.isBusy)

            if organizerEnabled {
                Text(organizerText.enabledCaption)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                organizerDestinationRow

                HStack {
                    Button(organizerText.organizeNow) { organizer.runNow() }
                        .buttonStyle(.borderedProminent)
                        .disabled(organizer.isBusy)
                    if organizer.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(organizerText.undo) { organizer.undoLastRun() }
                        .disabled(!organizer.canUndo || organizer.isBusy)
                }
                organizerStatus
            }
        } header: {
            HStack(spacing: 8) {
                Text(organizerText.title)
                Text(organizerText.experimental.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(.orange)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
        }
    }

    @ViewBuilder
    private var organizerOptionsSection: some View {
        if organizerEnabled {
            Section {
                Picker(organizerText.organization, selection: $organizerLayout) {
                    Text(organizerText.flat).tag(WhatsAppOrganizerLayout.flat.rawValue)
                    Text(organizerText.byType).tag(WhatsAppOrganizerLayout.category.rawValue)
                    Text(organizerText.byMonth).tag(WhatsAppOrganizerLayout.month.rawValue)
                }
                .onChange(of: organizerLayout) { _, _ in organizer.syncWithPreferences() }
                .disabled(organizer.isBusy)

                Picker(selection: $duplicateAction) {
                    Text(organizerText.trashDuplicate)
                        .tag(WhatsAppDuplicateAction.trashNew.rawValue)
                    Text(organizerText.keepBoth)
                        .tag(WhatsAppDuplicateAction.keepBoth.rawValue)
                    Text(organizerText.replaceExisting)
                        .tag(WhatsAppDuplicateAction.replaceExisting.rawValue)
                } label: {
                    SettingsLabel(organizerText.duplicateAction, caption: organizerText.duplicateCaption)
                }
                .onChange(of: duplicateAction) { _, _ in organizer.syncWithPreferences() }
                .disabled(organizer.isBusy)

                Group {
                    DisclosureHeaderRow(isExpanded: $showingOrganizerFileTypes) {
                        Text(text.fileTypes)
                        Spacer()
                    }
                    if showingOrganizerFileTypes {
                        Group {
                            Toggle(text.allTypes, isOn: allOrganizerCategoriesBinding)
                                .toggleStyle(.checkbox)
                            organizerCategoryPair(.image, .video)
                            organizerCategoryPair(.audio, .document)
                            organizerCategoryPair(.archive, .other)
                        }
                        .disclosureIndent()
                    }
                }
                .disabled(organizer.isBusy)

                SettingsMoreOptions {
                    Picker(organizerText.delay, selection: $organizerDelay) {
                        ForEach(WhatsAppDownloadSupport.allowedOrganizerDelayMinutes, id: \.self) {
                            Text(String(format: organizerText.minutesFormat, $0)).tag($0)
                        }
                    }
                    .onChange(of: organizerDelay) { _, value in
                        organizerDelay = WhatsAppDownloadSupport.sanitizedOrganizerDelayMinutes(value)
                        organizer.syncWithPreferences()
                    }
                    .disabled(organizer.isBusy)
                }
            } header: {
                Text(layoutText.behavior)
            } footer: {
                SettingsCaptionText(organizerText.privacyNote)
            }
        }
    }

    private var organizerDestinationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(organizerText.destination)
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(organizerDestinationDisplayPath)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(organizerText.chooseFolder) { chooseOrganizerDestination() }
                    .controlSize(.small)
                    .disabled(organizer.isBusy)
                if !organizerDestination.isEmpty {
                    Button(organizerText.useDefault) {
                        _ = organizer.setDestination(nil)
                    }
                    .controlSize(.small)
                    .disabled(organizer.isBusy)
                }
                Button {
                    if let url = WhatsAppDownloadOrganizer.destinationURL() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "arrow.forward.circle")
                }
                .buttonStyle(.borderless)
                .help(l10n.s.cleanerRevealInFinder)
            }
        }
    }

    @ViewBuilder
    private var organizerStatus: some View {
        switch organizer.phase {
        case .organizing, .undoing:
            Text(organizerText.working)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case let .done(moved, duplicates, failed):
            Text(String(format: organizerText.resultFormat, moved, duplicates, failed))
                .font(.subheadline)
                .foregroundStyle(failed == 0 ? Color.green : Color.orange)
        case .failed:
            Text(String(format: organizerText.resultFormat, 0, 0, 1))
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .idle, .waiting:
            if organizerLastRun > 0 {
                Text(String(format: organizerText.lastRunFormat,
                            Self.activityDate.string(from: Date(timeIntervalSince1970: organizerLastRun)),
                            organizerLastMoved, organizerLastDuplicates, organizerLastFailed))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(organizerText.neverRun)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func organizerCategoryPair(_ first: WhatsAppDownloadCategory,
                                       _ second: WhatsAppDownloadCategory) -> some View {
        HStack(spacing: 24) {
            Toggle(categoryName(first), isOn: organizerCategoryBinding(first))
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(categoryName(second), isOn: organizerCategoryBinding(second))
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var allOrganizerCategoriesBinding: Binding<Bool> {
        Binding(
            get: { enabledOrganizerCategories.count == WhatsAppDownloadCategory.allCases.count },
            set: { all in
                organizerCategoriesRaw = WhatsAppDownloadSupport.encodedCategories(
                    all ? Set(WhatsAppDownloadCategory.allCases) : [])
                organizer.syncWithPreferences()
            })
    }

    private func organizerCategoryBinding(_ category: WhatsAppDownloadCategory) -> Binding<Bool> {
        Binding(
            get: { enabledOrganizerCategories.contains(category) },
            set: { enabled in
                var categories = enabledOrganizerCategories
                if enabled { categories.insert(category) } else { categories.remove(category) }
                organizerCategoriesRaw = WhatsAppDownloadSupport.encodedCategories(categories)
                organizer.syncWithPreferences()
            })
    }

    private var enabledOrganizerCategories: Set<WhatsAppDownloadCategory> {
        WhatsAppDownloadSupport.decodedCategories(organizerCategoriesRaw)
    }

    private var organizerDestinationDisplayPath: String {
        (WhatsAppDownloadOrganizer.destinationURL()?.path ?? "~/Downloads/WhatsApp")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseOrganizerDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = WhatsAppDownloadOrganizer.destinationURL()
        guard panel.runModal() == .OK else { return }
        showingInvalidDestination = !organizer.setDestination(panel.url)
    }

    private func categoryPair(_ first: WhatsAppDownloadCategory,
                              _ second: WhatsAppDownloadCategory) -> some View {
        HStack(spacing: 24) {
            Toggle(categoryName(first), isOn: categoryBinding(first))
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(categoryName(second), isOn: categoryBinding(second))
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var allCategoriesBinding: Binding<Bool> {
        Binding(
            get: { enabledCategories.count == WhatsAppDownloadCategory.allCases.count },
            set: { all in
                categoriesRaw = WhatsAppDownloadSupport.encodedCategories(
                    all ? Set(WhatsAppDownloadCategory.allCases) : [])
                refreshResultsIfVisible()
            }
        )
    }

    private func categoryBinding(_ category: WhatsAppDownloadCategory) -> Binding<Bool> {
        Binding(
            get: { enabledCategories.contains(category) },
            set: { enabled in
                var categories = enabledCategories
                if enabled { categories.insert(category) } else { categories.remove(category) }
                categoriesRaw = WhatsAppDownloadSupport.encodedCategories(categories)
                refreshResultsIfVisible()
            }
        )
    }

    private var enabledCategories: Set<WhatsAppDownloadCategory> {
        WhatsAppDownloadSupport.decodedCategories(categoriesRaw)
    }

    @ViewBuilder
    private var manualSection: some View {
        Section {
            HStack {
                Button {
                    manager.scan()
                } label: {
                    Label(l10n.s.cleanerScan, systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.phase == .scanning || manager.phase == .cleaning)
                if manager.phase == .scanning {
                    ProgressView()
                        .controlSize(.small)
                    Text(l10n.s.cleanerScanning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            switch manager.phase {
            case .idle:
                EmptyView()
            case .scanning:
                EmptyView()
            case .results:
                resultsView
            case .cleaning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l10n.s.cleanerCleaning)
                        .foregroundStyle(.secondary)
                }
            case let .done(moved, bytes, failed):
                cleanupResult(moved: moved, bytes: bytes, failed: failed)
            case .failed:
                Text(text.scanFailed)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(l10n.s.urlCleanerManualTitle)
        } footer: {
            if manager.phase == .results, !manager.candidates.isEmpty {
                SettingsCaptionText(text.manualIntro + " " + text.trashNote)
            } else {
                SettingsCaptionText(text.manualIntro)
            }
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        if manager.candidates.isEmpty {
            Label(text.noFiles, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text(String(format: text.resultsFormat,
                            manager.candidates.count, byteString(manager.totalBytes)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(text.selectRules) { manager.selectRules() }
                    .controlSize(.small)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(manager.candidates) { candidate in
                        candidateRow(candidate)
                        if candidate.id != manager.candidates.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 320)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )

            HStack {
                Spacer()
                Button(String(format: text.cleanSelectedFormat,
                              manager.selectedCount, byteString(manager.selectedBytes))) {
                    manager.cleanSelected(automatic: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.selectedCount == 0)
            }
        }
    }

    private func candidateRow(_ candidate: WhatsAppDownloadManager.Candidate) -> some View {
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(
                get: { manager.candidates.first(where: { $0.id == candidate.id })?.include ?? false },
                set: { manager.setInclude($0, for: candidate.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(candidate.excluded)
            Image(systemName: categoryIcon(candidate.category))
                .frame(width: 18)
                .foregroundStyle(candidate.excluded ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(categoryName(candidate.category)) · \(Self.shortDate.string(from: candidate.downloadedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(byteString(candidate.size))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if candidate.excluded {
                Button(text.manageAgain) { manager.removeExclusion(candidate.id) }
                    .controlSize(.mini)
            } else {
                Menu {
                    Button(text.keep) { manager.exclude(candidate.id) }
                    Button(l10n.s.cleanerRevealInFinder) { manager.reveal(candidate.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contextMenu {
            if candidate.excluded {
                Button(text.manageAgain) { manager.removeExclusion(candidate.id) }
            } else {
                Button(text.keep) { manager.exclude(candidate.id) }
            }
            Button(l10n.s.cleanerRevealInFinder) { manager.reveal(candidate.id) }
        }
    }

    private func cleanupResult(moved: Int, bytes: Int64, failed: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(failed == 0 ? Color.green : Color.orange)
            Text(String(format: text.notificationFormat, moved, byteString(bytes), failed))
                .font(.subheadline)
        }
    }

    private var activitySection: some View {
        Section {
            if lastCleanup > 0 {
                Text(String(format: text.lastRunFormat,
                            Self.activityDate.string(from: Date(timeIntervalSince1970: lastCleanup)),
                            lastCount, byteString(Int64(lastBytes)), lastFailed))
                    .font(.subheadline)
            } else {
                Text(text.neverRun)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if automatic, let next = scheduler.nextFire {
                Text(String(format: text.nextRunFormat, Self.activityDate.string(from: next)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(text.activity)
        } footer: {
            // With the organizer on, its privacy note already sits in the
            // Behavior footer, where it replaces the local-only note.
            SettingsCaptionText(organizerEnabled ? text.trashNote : text.localNote + " " + text.trashNote)
        }
    }

    private func enableAutomation(includeExisting: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(includeExisting, forKey: DefaultsKey.whatsAppDownloadsIncludeExisting)
        defaults.set(Date().timeIntervalSince1970,
                     forKey: DefaultsKey.whatsAppDownloadsAutomaticStartDate)
        automatic = true
        if notify { Notifier.requestPermission() }
        WhatsAppDownloadScheduler.shared.syncWithPreferences()
        manager.scan()
    }

    private func refreshResultsIfVisible() {
        switch manager.phase {
        case .results, .done:
            manager.scan()
        default:
            break
        }
    }

    private func categoryName(_ category: WhatsAppDownloadCategory) -> String {
        switch category {
        case .image: return text.image
        case .video: return text.video
        case .audio: return text.audio
        case .document: return text.document
        case .archive: return text.archive
        case .other: return text.other
        }
    }

    private func categoryIcon(_ category: WhatsAppDownloadCategory) -> String {
        switch category {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let activityDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
