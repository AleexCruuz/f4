// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct NotchView: View {
    @ObservedObject var service: NotchService
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var music = NotchMusicService.shared
    @ObservedObject private var launcher = QuickLauncherService.shared
    /// The header reads its trail from `service.path`, and the last crumb of
    /// that trail comes from the run. Without observing it here the breadcrumbs
    /// would keep naming Clipboard while the result page is on screen.
    @ObservedObject private var clipboardAI = ClipboardAIService.shared
    @Environment(\.colorSchemeContrast) private var contrast
    private var text: NotchStrings { FeatureStrings.notch(l10n.language) }

    var body: some View {
        surface
            .frame(width: service.surfaceSize.width, height: service.surfaceSize.height, alignment: .top)
            .background(.black)
            .foregroundStyle(.white)
            .contentShape(shape)
            .onChange(of: contrast) {
                DispatchQueue.main.async { service.refreshPresentation(animated: false) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
            .environment(\.notchPresentation, true)
            .tint(.white)
            .accessibilityIdentifier("notch.surface")
    }

    private var shape: NotchShape {
        NotchShape(attached: true, radius: NotchLayout.surfaceRadius(height: service.surfaceSize.height))
    }

    @ViewBuilder private var surface: some View {
        if let options = service.captureControls {
            if service.captureControlsCollapsed {
                HStack(spacing: 0) {
                    Image(systemName: options.selectedTool.systemImageName).frame(width: 28)
                    Color.clear.frame(width: service.geometry.cameraWidth)
                    Image(systemName: "chevron.down").frame(width: 28)
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            } else {
                NotchCaptureControlsView(options: options, service: service)
                    .padding(.horizontal, 18).padding(.top, service.geometry.safeContentTop)
            }
        } else if service.expanded, service.showingOnboarding {
            NotchOnboardingView(notch: service, topInset: service.geometry.safeContentTop) {
                appDelegate()?.finishOnboarding()
            }
            .frame(width: service.expandedSize.width, height: service.expandedSize.height, alignment: .top)
            .clipped()
        } else if service.expanded, showsMirror {
            // The camera page is the picture alone, filling the silhouette
            // under the cutout, so the island takes the picture's shape.
            NotchCameraView(size: CGSize(width: service.surfaceSize.width,
                                         height: service.surfaceSize.height - service.geometry.cameraHeight))
                .padding(.top, service.geometry.cameraHeight)
        } else if service.expanded {
            expanded
        } else if service.dragPlaceholder {
            Label(text.dropHint, systemImage: "tray.and.arrow.down")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.24),
                                      style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 18)
                .padding(.top, service.geometry.safeContentTop)
        } else if let notice = service.notice {
            Button {
                service.activateNotice(notice)
            } label: {
                NotchNoticeView(notice: notice, geometry: service.geometry)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notice.accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { service.activateNotice(notice) }
            .accessibilityHint(text.open)
            .transition(.opacity)
        } else if service.peeking {
            HStack {
                navigation
                Spacer(minLength: 8)
                NotchIconButton(symbol: "chevron.down", title: text.open) { service.open() }
            }
            .padding(.horizontal, NotchLayout.horizontalInset).padding(.top, service.geometry.safeContentTop)
        } else if let activity = service.compactActivity {
            switch activity {
            case .timer: NotchTimerStrip(service: service)
            case .downloads: NotchDownloadStrip(service: service)
            case .music: NotchMusicStrip(service: service)
            }
        } else {
            compact
                .transition(.opacity)
        }
    }

    private var showsMirror: Bool {
        service.selected == .camera && service.selectedMetric == nil
            && !service.showingSettings && !service.showingSections && !service.modules.isEmpty
    }

    private var compact: some View {
        HStack(spacing: 0) {
            if service.idleContent != .none, service.geometry.restingWingWidth > 0 {
                Group {
                    switch service.idleContent {
                    case .music:
                        if let artwork = music.artwork {
                            Image(nsImage: artwork).resizable().scaledToFill()
                                .frame(width: min(22, service.geometry.menuBarHeight - 6), height: min(22, service.geometry.menuBarHeight - 6))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    case .battery: Image(systemName: "battery.100percent").font(.system(size: 12))
                    case .none: EmptyView()
                    }
                }.frame(width: service.geometry.restingWingWidth)
                Color.clear.frame(width: service.geometry.cameraWidth)
                Group {
                    switch service.idleContent {
                    case .music:
                        if music.playback?.isPlaying == true {
                            NotchLiveEqualizerBars(bars: 3, barWidth: 2, height: 11,
                                                   tint: music.artworkTint?.color ?? .white)
                        }
                    case .battery:
                        if let percent = service.power.chargePercent {
                            Text("\(percent)%").font(.system(size: 9, weight: .medium)).monospacedDigit()
                        }
                    case .none: EmptyView()
                    }
                }.frame(width: service.geometry.restingWingWidth)
            } else { Color.clear }
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    private var expanded: some View {
        VStack(spacing: NotchLayout.spacing) {
            header.zIndex(1)
            if service.showingSections {
                NotchSectionsView(service: service)
            } else if service.showingSettings
                        || [.files, .music, .clipboard, .dictation, .calendar, .notifications, .timer, .camera, .downloads, .notes]
                            .contains(service.selected)
                || (service.selected == .captures && service.captureContent == nil) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if [.controls, .system, .tools].contains(service.selected), service.selectedMetric == nil {
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        content.fixedSize(horizontal: false, vertical: true)
                    }.scrollIndicators(.automatic)
                }
                .id(service.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            } else {
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, NotchLayout.horizontalInset)
        .padding(.top, service.geometry.safeContentTop)
        .padding(.bottom, NotchLayout.bottomInset)
        .frame(width: service.expandedSize.width, height: service.expandedSize.height, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            let quickActions = NotchQuickAccessConfiguration.current().actions
            // One header for every page. The trail names the location and the
            // ancestors in it are the only way up, so the grid button and the
            // back chevron it replaced are both gone.
            NotchBreadcrumbs(path: service.path, navigate: service.navigate)
            NotchUpdateControl(action: service.showUpdate)
            if service.path.last == .module(.tools), launcher.activeUtility == nil {
                NotchIconButton(symbol: launcher.isEditing ? "checkmark" : "slider.horizontal.3",
                                title: text.customizeTools, selected: launcher.isEditing) {
                    withAnimation(.easeOut(duration: 0.15)) { launcher.isEditing.toggle() }
                }
            }
            // Pin and the collapse chevron are gone from the header. Both
            // duplicated something the pointer already does — the panel closes
            // when you leave it, and staying open is what not leaving it means —
            // so they cost a permanent slot in a row that has to stay readable
            // at a glance. Settings is the one header action with no gesture
            // equivalent, so it stays.
            if !quickActions.contains(.settings), !service.showingSettings {
                NotchIconButton(symbol: "gearshape", title: l10n.s.menuSettings, action: service.openSettings)
            }
        }
        .frame(height: NotchLayout.headerHeight)
        .onAppear { UpdateService.shared.checkIfStale() }
    }

    private var navigation: some View {
        Button(action: service.toggleSections) {
            HStack(spacing: 9) {
                Image(systemName: "house")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(service.selected.title(l10n.language))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: NotchLayout.navigationHeight)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 12, lifts: false))
        .accessibilityLabel(text.switchSection)
        .accessibilityValue(service.selected.title(l10n.language))
        .accessibilityIdentifier("notch.navigation")
        .help(text.switchSection)
    }

    @ViewBuilder private var content: some View {
        if service.showingSettings {
            SettingsView(notchSize: service.contentSize)
        } else if let metric = service.selectedMetric {
            MetricDetailView(kind: metric)
        } else if service.modules.isEmpty {
            NotchEmptyView(symbol: "slider.horizontal.3", message: text.empty)
        } else {
            switch service.selected {
            case .timer: NotchTimerView()
            case .camera: NotchCameraView(size: service.contentSize)
            case .notifications: NotchNotificationsView()
            case .downloads: NotchDownloadsView()
            case .calendar: NotchCalendarView()
            case .controls: NotchControlsView(service: service)
            case .mixer: MixerSection(collapsible: false)
            case .music: NotchMusicView(compact: service.geometry.usesCompactContent)
            case .clipboard: NotchClipboardView(service: service)
            case .captures:
                if let capture = service.captureContent {
                    capture.frame(maxWidth: .infinity)
                } else {
                    RecentCapturesView(onClose: nil, notchHeight: service.contentSize.height)
                }
            case .files: NotchFilesView(service: service)
            case .system: NotchSystemView(columns: service.geometry.systemColumns) { service.showMetric($0) }
            case .tools: QuickLauncherView(notchSize: service.contentSize)
            case .notes: NotchNotesView(size: service.contentSize)
            case .dictation: NotchDictationHistoryView()
            }
        }
    }
}

/// Square where it meets the menu bar, straight down the sides, and rounded
/// only at the bottom, at every size the panel takes.
struct NotchShape: Shape {
    var attached: Bool
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard attached else { return Path(roundedRect: rect, cornerRadius: radius) }
        let bottom = min(radius, rect.height / 2, rect.width / 2)
        let tangent: CGFloat = 0.55228475
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - bottom))
        path.addCurve(to: CGPoint(x: rect.width - bottom, y: rect.height),
                      control1: CGPoint(x: rect.width, y: rect.height - bottom * (1 - tangent)),
                      control2: CGPoint(x: rect.width - bottom * (1 - tangent), y: rect.height))
        path.addLine(to: CGPoint(x: bottom, y: rect.height))
        path.addCurve(to: CGPoint(x: 0, y: rect.height - bottom),
                      control1: CGPoint(x: bottom * (1 - tangent), y: rect.height),
                      control2: CGPoint(x: 0, y: rect.height - bottom * (1 - tangent)))
        path.closeSubpath()
        return path
    }
}

extension NotchModule: PanelOrderItem {
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .timer: return FeatureStrings.notchActivities(language).timer
        case .camera: return FeatureStrings.notchActivities(language).camera
        case .notifications: return FeatureStrings.notchNotifications(language).title
        case .downloads: return FeatureStrings.notchFiles(language).downloadsTitle
        case .calendar: return FeatureStrings.notchCalendar(language).title
        case .controls: return FeatureStrings.notch(language).controls
        case .mixer: return L10n.shared.s.mixerSection
        case .music: return FeatureStrings.notch(language).music
        case .clipboard: return FeatureStrings.clipboard(language).title
        case .captures: return FeatureStrings.recentCaptures(language).title
        case .files: return FeatureStrings.notch(language).files
        case .system: return FeatureStrings.notch(language).system
        case .tools: return FeatureStrings.notch(language).tools
        case .notes: return FeatureStrings.notes(language).title
        case .dictation: return FeatureStrings.dictation(language).pageTitle
        }
    }
}
