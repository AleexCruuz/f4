// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import Combine
import SwiftUI

/// The first run, drawn inside the notch: the mark and one line about the
/// app, how the notch opens, the tools to install and the grants they need.
/// The same view fills the fallback window when the notch cannot present.
struct NotchOnboardingView: View {
    /// Nil in the fallback window, where there is no island to step aside.
    var notch: NotchService?
    var topInset: CGFloat
    var onFinish: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    /// Persisted so the flow resumes where it stopped: macOS relaunches the
    /// app when Screen Recording is granted.
    @AppStorage(DefaultsKey.onboardingStep) private var stepIndex = 0
    @State private var tools = OnboardingSupport.tools(installed: NotchOnboardingView.installed)
    @State private var appeared = false
    @State private var forward = true
    @Namespace private var brand
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: OnboardingStrings { FeatureStrings.onboarding(l10n.language) }
    private var step: OnboardingStep { OnboardingStep(rawValue: stepIndex) ?? .welcome }
    private static var installed: Set<AppFeature> { Set(AppFeature.allCases.filter(\.isAvailable)) }
    private static let alwaysIncluded: [NotchModule] = [.clipboard, .dictation, .notes, .camera, .controls, .music]

    var body: some View {
        ZStack(alignment: .top) {
            if step == .welcome {
                welcome.transition(.opacity)
            } else {
                page.transition(.opacity)
            }
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.12)) { appeared = true } }
        }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            BrandMark(width: 92)
                .matchedGeometryEffect(id: "mark", in: brand)
                .offset(y: appeared ? 0 : 22)
                .opacity(appeared ? 1 : 0)
                .accessibilityLabel(AppInfo.name)
            Text(text.slogan)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.35), value: appeared)
            primaryButton(text.continueTitle, action: advance)
                .padding(.top, 24)
                .offset(y: appeared ? 0 : -12)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8).delay(0.5), value: appeared)
            Spacer(minLength: 0)
            languageMenu
                .padding(.bottom, 14)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.7), value: appeared)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, NotchLayout.horizontalInset)
    }

    private var languageMenu: some View {
        Menu {
            Picker(text.language, selection: $l10n.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(l10n.language.displayName, systemImage: "globe")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(text.language)
    }

    // MARK: - Pages

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BrandMark(width: 30)
                    .matchedGeometryEffect(id: "mark", in: brand)
                    .accessibilityHidden(true)
                Spacer()
                pageDots
            }
            .frame(height: 24)

            Group {
                switch step {
                case .welcome: EmptyView()
                case .howItWorks: howItWorks
                case .tools: toolPicker
                case .access: access
                }
            }
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .opacity))
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

            HStack {
                Button(text.back) { go(to: step.previous ?? .welcome, forward: false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                primaryButton(step == .access ? text.finish : text.continueTitle, action: advance)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, NotchLayout.horizontalInset)
        .padding(.bottom, 20)
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingStep.allCases.dropFirst(), id: \.self) { page in
                Capsule()
                    .fill(.white.opacity(page == step ? 0.9 : 0.22))
                    .frame(width: page == step ? 16 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: step)
        .accessibilityHidden(true)
    }

    private func title(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 20, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.65))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func symbolWell(_ symbol: String, filled: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(filled ? Color.black : Color.white)
            .frame(width: 32, height: 32)
            .background(filled ? Color.white : Color.white.opacity(NotchFill.raised),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: How it works

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 20) {
            title(String(format: text.howTitleFormat, AppInfo.name))
            VStack(alignment: .leading, spacing: 16) {
                howRow("cursorarrow.motionlines", text.openTitle, text.openBody)
                howRow("house", text.homeTitle, text.homeBody)
                howRow("mic", text.dictateTitle, text.dictateBody)
            }
        }
    }

    private func howRow(_ symbol: String, _ heading: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            symbolWell(symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(heading).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Tools

    private var toolPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(text.toolsTitle)
            caption(text.toolsBody).padding(.top, 6)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { includedLabel; includedChips }
                VStack(alignment: .leading, spacing: 6) { includedLabel; includedChips }
            }
            .padding(.top, 14)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(OnboardingTool.allCases) { tool in toolTile(tool) }
                }
            }
            .scrollIndicators(.never)
            .padding(.top, 14)
        }
    }

    private var includedLabel: some View {
        Label(text.alwaysIncluded, systemImage: "lock.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize()
    }

    private var includedChips: some View {
        HStack(spacing: 6) {
            ForEach(Self.alwaysIncluded) { module in
                Label(module.title(l10n.language), systemImage: module.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(.white.opacity(NotchFill.quiet), in: Capsule())
            }
        }
    }

    private func toolTile(_ tool: OnboardingTool) -> some View {
        let on = tools.contains(tool)
        let blocked = tool.features.compactMap(\.installBlockedReason)
        let unavailable = !on && blocked.count == tool.features.count
        let (name, detail) = describe(tool)
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8)) {
                if on { tools.remove(tool) } else { tools.insert(tool) }
            }
        } label: {
            HStack(spacing: 10) {
                symbolWell(tool.symbol, filled: on)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(on ? 1 : 0.25))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .modifier(NotchControlSurface(cornerRadius: 12, selected: on))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(NotchPressStyle(pressedScale: 0.97))
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .help(unavailable ? blocked.first ?? detail : detail)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func describe(_ tool: OnboardingTool) -> (String, String) {
        switch tool {
        case .system: return (text.systemTitle, text.systemDetail)
        case .keepAwake: return (text.keepAwakeTitle, text.keepAwakeDetail)
        case .mixer: return (text.mixerTitle, text.mixerDetail)
        case .captures: return (text.capturesTitle, text.capturesDetail)
        case .calendar: return (text.calendarTitle, text.calendarDetail)
        case .timer: return (text.timerTitle, text.timerDetail)
        case .commandBar: return (text.commandBarTitle, text.commandBarDetail)
        case .windows: return (text.windowsTitle, text.windowsDetail)
        case .files: return (text.filesTitle, text.filesDetail)
        case .downloads: return (text.downloadsTitle, text.downloadsDetail)
        case .launcher: return (text.launcherTitle, text.launcherDetail)
        }
    }

    // MARK: Access

    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(text.accessTitle)
            caption(text.accessBody).padding(.top, 6)
            VStack(spacing: 8) {
                ForEach(OnboardingSupport.permissions(choosing: tools), id: \.self) { permissionRow($0) }
            }
            .padding(.top, 16)
        }
    }

    private func permissionRow(_ permission: AppPermission) -> some View {
        let state = grant(of: permission)
        return HStack(spacing: 12) {
            symbolWell(permission.symbolName)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.name(FeatureStrings.hub(l10n.language)))
                    .font(.system(size: 13, weight: .semibold))
                Text(reason(for: permission))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if state == .granted {
                Label(text.allowed, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button { request(permission) } label: {
                    Text(state == .denied ? text.openSettings : text.allow)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(.white.opacity(NotchFill.selected), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(NotchPressStyle(pressedScale: 0.95))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
        .modifier(NotchControlSurface(cornerRadius: 14))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: state)
    }

    private enum Grant { case granted, denied, pending }

    private func grant(of permission: AppPermission) -> Grant {
        switch permission {
        case .accessibility: return permissions.accessibility ? .granted : .pending
        case .screenRecording: return permissions.screenRecording ? .granted : .pending
        case .microphone:
            switch permissions.microphone {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined, .unknown: return .pending
            }
        default: return .pending
        }
    }

    private func reason(for permission: AppPermission) -> String {
        switch permission {
        case .screenRecording: return text.reasonScreenRecording
        case .microphone: return text.reasonMicrophone
        default: return text.reasonAccessibility
        }
    }

    /// Each request first moves the island out of the way, because the
    /// system prompt and System Settings both open where it hangs.
    private func request(_ permission: AppPermission) {
        let shared = Permissions.shared
        switch permission {
        case .accessibility:
            stepAside(until: shared.$accessibility) { shared.requestAccessibility() }
        case .screenRecording:
            stepAside(until: shared.$screenRecording) { shared.requestScreenRecording() }
        case .microphone where shared.microphone == .denied:
            stepAside(until: shared.$microphone.map { $0 == .granted }) { shared.openMicrophoneSettings() }
        case .microphone:
            stepAside(until: shared.$microphone.map { $0 == .granted || $0 == .denied }) { shared.requestMicrophone() }
        default:
            break
        }
    }

    private func stepAside<Answer: Publisher>(until answered: Answer, then request: @escaping () -> Void)
    where Answer.Output == Bool, Answer.Failure == Never {
        if let notch { notch.stepAsideFromOnboarding(until: answered.eraseToAnyPublisher(), then: request) }
        else { request() }
    }

    // MARK: - Moving between pages

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .frame(minWidth: 120, minHeight: 34)
                .background(.white, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle(pressedScale: 0.96))
        .keyboardShortcut(.defaultAction)
    }

    private func advance() {
        guard let next = step.next else {
            stepIndex = OnboardingStep.welcome.rawValue
            onFinish()
            return
        }
        // Leaving the picker is the moment the choice applies: the access
        // page asks only for what the chosen tools need.
        if step == .tools {
            let installed = Self.installed
            FeatureRuntime.shared.replaceAvailable(
                with: OnboardingSupport.installedFeatures(choosing: tools, installed: installed),
                enabling: OnboardingSupport.enableKeys(choosing: tools, installed: installed))
        }
        go(to: next, forward: true)
    }

    private func go(to target: OnboardingStep, forward: Bool) {
        self.forward = forward
        withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)) {
            stepIndex = target.rawValue
        }
        notch?.onboardingStepChanged()
    }
}
