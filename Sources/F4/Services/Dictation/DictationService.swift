// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import Foundation

/// Hold the shortcut and talk; let go and the words land where the cursor is.
///
/// Audio never leaves the Mac: stretches go to a whisper.cpp server on
/// loopback while the speaker is still talking, and the optional cleanup to
/// the same local model runner Clipboard AI uses. Everything here runs on the
/// main thread; the recorder and the network hop off it and come back.
final class DictationService: ObservableObject {
    static let shared = DictationService()

    enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool)
        case transcribing
        case polishing
        case finished(DictationDelivery)
        case failed(DictationError)

        var isRecording: Bool {
            if case .listening = self { return true }
            return false
        }

        var isProcessing: Bool { self == .transcribing || self == .polishing }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var levels = [Double](repeating: 0, count: DictationService.meterBars)
    @Published private(set) var engineState: DictationEngine.State = .stopped
    @Published private(set) var lastTranscript = ""
    /// What the live model has heard so far, refined as the user speaks.
    @Published private(set) var liveText = ""
    @Published private(set) var shortcutRegistrationFailed = false

    static let meterBars = 9

    let engine = DictationEngine()
    private let hotkey = QuickToolHotkey(id: 70)
    /// Registered only while listening, so Escape belongs to other apps the
    /// rest of the time.
    private let escapeHotkey = QuickToolHotkey(id: 71)
    private var trigger = DictationTrigger()
    private var recorder: DictationRecorder?
    private var transcription: Task<[String], Error>?
    private var pipeline: Task<Void, Never>?
    /// Every asynchronous step checks it before publishing, so a cancelled or
    /// replaced dictation can never paste into the next one.
    private var sessionID = UUID()
    private var targetAppName: String?
    private var listeningSince: TimeInterval = 0
    /// How long the microphone was open, kept for the history entry.
    private var spokenDuration: TimeInterval = 0
    private var maximumWork: DispatchWorkItem?
    /// The live transcriber of the current dictation (`DictationLiveTranscriber`
    /// on macOS 26), typed loosely because the class does not exist before.
    private var live: AnyObject?
    private var liveStart: Task<Bool, Never>?
    /// Whisper writes the final text when it is set up: it spells mixed
    /// Spanish and English far better than the live model, which then only
    /// shows the words as they come and stands in if Whisper fails.
    private var usesWhisper = false
    private var fnGesture = DictationFnGesture()
    private var fnTap: DictationFnTap?
    private var fnIsDown = false
    private var fnTick: DispatchWorkItem?
    private var levelPeak = 0.0
    private var levelPublishedAt: TimeInterval = 0
    private var settleWork: DispatchWorkItem?
    private let runnerSession: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        runnerSession = URLSession(configuration: configuration)
        engine.onStateChange = { [weak self] state in self?.engineState = state }
        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        escapeHotkey.onPress = { [weak self] in self?.cancel() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.engine.stop()
        }
    }

    // MARK: - Preferences

    var isEnabled: Bool {
        AppFeature.dictation.isAvailable && UserDefaults.standard.bool(forKey: DefaultsKey.dictationEnabled)
    }

    var polishMode: DictationPolishMode {
        DictationPolishMode.sanitized(UserDefaults.standard.string(forKey: DefaultsKey.dictationPolishMode))
    }

    var language: String {
        DictationLanguage.code(setting: UserDefaults.standard.string(forKey: DefaultsKey.dictationLanguage) ?? "",
                               preferredLanguages: Locale.preferredLanguages)
    }

    var vocabulary: [String] {
        DictationTranscript.vocabulary(from: UserDefaults.standard.string(forKey: DefaultsKey.dictationVocabulary) ?? "")
    }

    func syncWithPreferences() {
        let enabled = isEnabled
        let registered = hotkey.sync(enabled: enabled, shortcut: GlobalShortcutRole.dictation.savedShortcut)
        shortcutRegistrationFailed = enabled && !registered
        syncFnMonitor(enabled: enabled)
        if enabled {
            engine.preflight()
            // Loaded ahead of the first dictation: a cold start is seconds.
            if engine.isConfigured { checkEngine() }
        } else {
            cancel()
            engine.stop()
        }
    }

    /// The model file or the address changed: the next dictation starts the
    /// server again with them.
    func engineSettingsChanged() {
        engine.stop()
        engine.preflight()
    }

    func checkEngine() {
        Task { @MainActor [weak self] in _ = try? await self?.engine.ensureRunning() }
    }

    // MARK: - The shortcut

    private func handlePress() {
        switch trigger.press(at: ProcessInfo.processInfo.systemUptime, isRecording: phase.isRecording) {
        case .start:
            begin()
            if phase.isRecording { chime() }
        case .finish: finish()
        case .none: break
        }
    }

    private func handleRelease() {
        switch trigger.release(at: ProcessInfo.processInfo.systemUptime, isRecording: phase.isRecording) {
        case .finish:
            finish()
        case .none:
            if trigger.isLatched, phase == .listening(handsFree: false) {
                phase = .listening(handsFree: true)
                present()
            }
        case .start:
            break
        }
    }

    // MARK: - Fn

    /// Fn is a modifier, so it never reaches a hot key: it is read at an
    /// event tap, which needs Accessibility. While the tap holds Fn the
    /// Globe key's own system action is off too, so no app shows the emoji
    /// picker, switches the input source or starts Apple's dictation.
    private func syncFnMonitor(enabled: Bool) {
        guard enabled != (fnTap != nil) else { return }
        guard enabled else {
            fnTap = nil
            fnTick?.cancel()
            fnGesture.reset()
            fnIsDown = false
            DictationGlobeKey.giveBack()
            return
        }
        fnTap = DictationFnTap { [weak self] event, time in self?.handleFn(event, at: time) }
        if fnTap != nil { DictationGlobeKey.takeOver() }
    }

    private func handleFn(_ event: DictationFnKey.Event, at now: TimeInterval) {
        guard fnTap != nil else { return }
        switch event {
        case let .fn(isDown):
            guard isDown != fnIsDown else { return }
            fnIsDown = isDown
            apply(isDown ? fnGesture.fnDown(at: now) : fnGesture.fnUp(at: now))
            if case let .awaitingSecondTap(until) = fnGesture.state {
                fnTick?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.apply(self.fnGesture.tick(at: ProcessInfo.processInfo.systemUptime))
                }
                fnTick = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (until - now) + 0.02, execute: work)
            }
        case .otherModifier:
            // Another modifier joining Fn means a shortcut, not dictation.
            if fnIsDown { apply(fnGesture.otherKey()) }
        case .otherKey:
            apply(fnGesture.otherKey())
        case .globe, .ignored:
            break
        }
    }

    private func apply(_ action: DictationFnGesture.Action) {
        switch action {
        case .start:
            if !phase.isRecording { begin() }
            chimeIfHeld()
        case .finish: finish()
        case .latch:
            if phase == .listening(handsFree: false) {
                phase = .listening(handsFree: true)
                present()
                chime()
            }
        case .cancel: if phase.isRecording { cancel() }
        case .none: break
        }
    }

    /// Fn is also a modifier, so its press only chimes once it is surely a
    /// dictation: held past a tap, or tapped twice (`.latch`).
    private func chimeIfHeld() {
        guard case let .pressed(pressedAt) = fnGesture.state else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationFnGesture.holdThreshold) { [weak self] in
            guard let self, self.phase.isRecording,
                  case let .pressed(stillPressedAt) = self.fnGesture.state, stillPressedAt == pressedAt else { return }
            self.chime()
        }
    }

    private func chime() {
        guard let sound = NSSound(named: "Tink") else { return }
        sound.volume = 0.5
        sound.play()
    }

    /// Clicking the notice while listening is the same as letting go.
    /// A click on the notch: stops a recording, or takes the copy it offers
    /// when the text had nowhere to go.
    func noticeActivated() {
        if phase.isRecording {
            finish()
        } else if phase == .finished(.notPasted) {
            copyLastTranscript()
            settle(.finished(.copied))
        }
    }

    // MARK: - Recording

    private func begin() {
        guard isEnabled, !phase.isProcessing else {
            trigger.reset()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // The prompt takes the keyboard; the next press records.
            trigger.reset()
            Permissions.shared.requestMicrophone()
            return
        default:
            trigger.reset()
            fail(.microphoneDenied)
            return
        }

        settleWork?.cancel()
        pipeline?.cancel()
        transcription?.cancel()
        transcription = nil
        let id = UUID()
        sessionID = id
        let recorder = DictationRecorder()
        recorder.onLevel = { [weak self] level in self?.push(level: level) }
        recorder.onSegment = { [weak self] samples in
            guard let self, self.sessionID == id else { return }
            if self.usesWhisper { self.enqueue(samples) }
        }
        liveText = ""
        live = nil
        liveStart = nil
        usesWhisper = engine.isConfigured
        startLive(recorder: recorder, session: id)
        recorder.onInterrupted = { [weak self] in
            guard let self, self.sessionID == id else { return }
            self.finish()
        }
        do {
            try recorder.start()
        } catch {
            trigger.reset()
            fail(.microphoneUnavailable)
            return
        }
        self.recorder = recorder
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        levels = [Double](repeating: 0, count: Self.meterBars)
        phase = .listening(handsFree: false)
        listeningSince = ProcessInfo.processInfo.systemUptime
        escapeHotkey.sync(enabled: true, shortcut: GlobalShortcut(keyCode: Int64(kVK_Escape), modifiers: []))
        present()

        // Every engine loads while the speaker is still talking, so no
        // start-up is paid after letting go.
        if usesWhisper { checkEngine() }
        if polishMode != .off { warmPolisher() }

        let work = DispatchWorkItem { [weak self] in self?.finish() }
        maximumWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationTrigger.maximumDuration, execute: work)
    }

    /// The recorder reports every ~10 ms; the notch redraws at most every
    /// 25 ms, showing the loudest reading since the last redraw.
    private func push(level: Double) {
        guard phase.isRecording else { return }
        levelPeak = max(levelPeak, level)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - levelPublishedAt >= 0.025 else { return }
        levelPublishedAt = now
        var next = levels
        next.removeFirst()
        next.append(levelPeak)
        levels = next
        levelPeak = 0
    }

    // MARK: - Live transcription

    private func startLive(recorder: DictationRecorder, session id: UUID) {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        let transcriber = DictationLiveTranscriber()
        transcriber.onText = { [weak self] finalized, volatile in
            guard let self, self.sessionID == id else { return }
            self.liveText = DictationTranscript.joined([finalized, volatile])
        }
        recorder.onChunk = { [weak transcriber] chunk in transcriber?.append(chunk) }
        live = transcriber
        let language = language
        let vocabulary = vocabulary
        liveStart = Task { @MainActor in
            do {
                try await transcriber.start(language: language, vocabulary: vocabulary)
                return true
            } catch {
                return false
            }
        }
        #endif
    }

    /// The live model's final text, or "" when there is none.
    @MainActor
    private func finishLive() async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let transcriber = live as? DictationLiveTranscriber,
           await liveStart?.value == true {
            return await transcriber.finish()
        }
        #endif
        return ""
    }

    private func cancelLive() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { (live as? DictationLiveTranscriber)?.cancel() }
        #endif
        live = nil
        liveStart = nil
    }

    private func stopListening() {
        maximumWork?.cancel()
        maximumWork = nil
        escapeHotkey.unregister()
        trigger.reset()
    }

    private func finish() {
        guard phase.isRecording, let recorder else { return }
        self.recorder = nil
        stopListening()
        spokenDuration = ProcessInfo.processInfo.systemUptime - listeningSince
        phase = .transcribing
        present()
        let id = sessionID
        recorder.stop { [weak self] tail in
            guard let self, self.sessionID == id else { return }
            if self.usesWhisper, let tail { self.enqueue(tail) }
            let chain = self.transcription
            self.pipeline = Task { @MainActor [weak self] in
                await self?.complete(chain, session: id)
            }
        }
    }

    /// Escape, or switching the feature off: nothing is transcribed or pasted.
    func cancel() {
        guard phase != .idle else { return }
        sessionID = UUID()
        recorder?.cancel()
        recorder = nil
        cancelLive()
        fnGesture.reset()
        stopListening()
        transcription?.cancel()
        transcription = nil
        pipeline?.cancel()
        pipeline = nil
        settle(.idle)
    }

    // MARK: - Transcribing

    /// Stretches are transcribed strictly in order, each one prompted with
    /// the text before it, so a sentence cut at a pause still reads as one.
    private func enqueue(_ samples: [Float]) {
        let previous = transcription
        let language = language
        let vocabulary = vocabulary
        transcription = Task { @MainActor [weak self] in
            var parts = try await previous?.value ?? []
            guard let self else { return parts }
            let prompt = DictationTranscript.whisperPrompt(vocabulary: vocabulary,
                                                           previous: DictationTranscript.joined(parts))
            let text = try await self.engine.transcribe(samples, language: language, prompt: prompt)
            if !DictationTranscript.isHallucination(text) { parts.append(text) }
            return parts
        }
    }

    @MainActor
    private func complete(_ chain: Task<[String], Error>?, session id: UUID) async {
        var whisperText = ""
        var failure: DictationError?
        if let chain {
            do {
                whisperText = DictationTranscript.joined(try await chain.value)
            } catch {
                guard sessionID == id, !(error is CancellationError) else { return }
                failure = error as? DictationError ?? .transcriptionFailed
            }
        }
        guard sessionID == id else { return }
        if !whisperText.isEmpty {
            cancelLive()
            await completeText(whisperText, session: id)
            return
        }
        // Whisper is not set up, failed, or heard nothing: the live model's
        // text is the answer.
        let liveText = await finishLive()
        cancelLive()
        guard sessionID == id else { return }
        guard !liveText.isEmpty else {
            fail(failure ?? .noSpeech)
            return
        }
        await completeText(liveText, session: id)
    }

    /// The same finish for either engine: tidy, clean up when it helps, paste.
    @MainActor
    private func completeText(_ raw: String, session id: UUID) async {
        let language = language
        let vocabulary = vocabulary
        var text = DictationTranscript.tidy(raw, language: language, vocabulary: vocabulary)
        guard !text.isEmpty else {
            fail(.noSpeech)
            return
        }
        let mode = polishMode
        if mode == .always || (mode == .smart && DictationTranscript.needsPolish(text, language: language)) {
            phase = .polishing
            present()
            // Anything short of a clean answer keeps the tidied transcript:
            // the model can make the text better, never make it disappear.
            if let polished = await polish(text, language: language, vocabulary: vocabulary) {
                text = DictationTranscript.applyingVocabulary(polished, vocabulary)
            }
            guard sessionID == id else { return }
        }
        let target = await Task.detached { DictationFocus.target() }.value
        guard sessionID == id else { return }
        deliver(text, target: target)
    }

    // MARK: - Cleanup

    private func runnerEndpoint() -> URL? {
        let raw = (UserDefaults.standard.string(forKey: DefaultsKey.clipboardAIEndpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try? ClipboardAIRunner.validatedEndpoint(raw.isEmpty ? Defaults.defaultClipboardAIEndpoint : raw)
    }

    private var runnerModel: String {
        let stored = UserDefaults.standard.string(forKey: DefaultsKey.clipboardAIModel) ?? ""
        return stored.isEmpty ? Defaults.defaultClipboardAIModel : stored
    }

    private func warmPolisher() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), DictationAppleModel.isAvailable {
            MainActor.assumeIsolated { DictationAppleModel.prewarm() }
            return
        }
        #endif
        let model = runnerModel
        guard ClipboardAIRunner.isValidModelName(model), let endpoint = runnerEndpoint() else { return }
        var request = URLRequest(url: endpoint.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": "", "stream": false, "keep_alive": "30m",
        ])
        let session = runnerSession
        Task { _ = try? await session.data(for: request) }
    }

    @MainActor
    func polish(_ text: String, language: String, vocabulary: [String]) async -> String? {
        let nonce = ClipboardAIPrompt.nonce()
        let instructions = DictationPrompt.system(languageName: DictationLanguage.englishName(language),
                                                  vocabulary: vocabulary, appName: targetAppName, nonce: nonce)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), DictationAppleModel.isAvailable {
            guard let raw = await DictationAppleModel.polish(
                text, instructions: instructions, prompt: DictationPrompt.userMessage(text, nonce: nonce))
            else { return nil }
            return DictationPrompt.accept(raw, transcript: text, nonce: nonce)
        }
        #endif
        let model = runnerModel
        guard ClipboardAIRunner.isValidModelName(model), let endpoint = runnerEndpoint() else { return nil }
        var request = URLRequest(url: endpoint.appending(path: "api/generate"))
        request.httpMethod = "POST"
        // A cold model takes longer than this; the tidied text is pasted
        // instead of making the user wait for it.
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "system": instructions,
            "prompt": DictationPrompt.userMessage(text, nonce: nonce),
            "stream": false,
            "keep_alive": "30m",
            "options": [
                "temperature": 0,
                "num_predict": DictationPrompt.tokenBudget(transcriptCharacters: text.count),
            ],
        ])
        guard let (data, response) = try? await runnerSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["response"] as? String
        else { return nil }
        return DictationPrompt.accept(raw, transcript: text, nonce: nonce)
    }

    // MARK: - Delivery

    private func deliver(_ text: String, target: DictationPasteTarget) {
        lastTranscript = text
        let delivery = DictationDelivery.decide(secureInput: IsSecureEventInputEnabled(),
                                                accessibilityTrusted: AXIsProcessTrusted(), target: target)
        if DictationHistory.keeps(delivery) {
            DictationHistoryService.shared.record(text, duration: spokenDuration, appName: targetAppName)
        }
        if delivery == .notPasted {
            // The offer lives in the notch. Without one on screen the text
            // goes to the clipboard, as it would have before there was an offer.
            if !settle(.finished(.notPasted)) {
                copy(text)
                Notifier.post(title: FeatureStrings.dictation(L10n.shared.language).pageTitle,
                              body: FeatureStrings.dictation(L10n.shared.language).statusCopied)
                settle(.finished(.copied))
            }
            return
        }
        guard delivery == .pasted else {
            copy(text)
            settle(.finished(delivery))
            return
        }
        let id = sessionID
        let started = TransientPaste.shared.paste(text, didFail: { [weak self] in
            guard let self, self.sessionID == id else { return }
            self.copy(text)
            self.settle(.finished(.copied))
        })
        if started {
            settle(.finished(.pasted))
        } else {
            copy(text)
            settle(.finished(.copied))
        }
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        copy(lastTranscript)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func fail(_ error: DictationError) {
        settle(.failed(error))
    }

    /// Shows the outcome for a moment, then clears it. Returns whether the
    /// notch is showing it.
    @discardableResult
    private func settle(_ outcome: Phase) -> Bool {
        settleWork?.cancel()
        phase = outcome
        levels = [Double](repeating: 0, count: Self.meterBars)
        let shown = present()
        let language = L10n.shared.language
        if let message = DictationNoticeContent.notification(for: outcome, language: language) {
            Notifier.post(title: FeatureStrings.dictation(language).pageTitle, body: message)
        }
        guard outcome != .idle else { return shown }
        let linger: TimeInterval
        switch outcome {
        case .failed: linger = 3.5
        case .finished(.pasted): linger = 1.2
        case .finished(.notPasted): linger = DictationNoticeLayout.actionLinger
        default: linger = 3
        }
        clear(outcome, after: linger)
        return shown
    }

    private func clear(_ outcome: Phase, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == outcome else { return }
            // The copy offer does not leave from under a pointer on its way
            // to the button.
            if outcome == .finished(.notPasted), NotchService.shared.isPointerInside {
                self.clear(outcome, after: 1)
                return
            }
            self.phase = .idle
            self.present()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Notch

    /// Returns whether the notch is showing the dictation.
    @discardableResult
    private func present() -> Bool {
        guard let notice = DictationNoticeContent.notice(for: phase, language: L10n.shared.language) else {
            NotchService.shared.dismissNotice(of: .dictation)
            return false
        }
        return NotchService.shared.show(notice)
    }
}

/// What the notch says for each phase.
enum DictationNoticeContent {
    static func notice(for phase: DictationService.Phase, language: AppLanguage) -> NotchNotice? {
        let text = FeatureStrings.dictation(language)
        switch phase {
        case .idle:
            return nil
        case let .listening(handsFree):
            return NotchNotice(event: .dictation,
                               title: handsFree ? text.statusHandsFree : text.statusListening,
                               detail: "", symbol: "mic.fill")
        case .transcribing:
            return NotchNotice(event: .dictation, title: text.statusTranscribing, detail: "",
                               symbol: "waveform")
        case .polishing:
            return NotchNotice(event: .dictation, title: text.statusPolishing, detail: "",
                               symbol: "wand.and.sparkles")
        case let .finished(delivery):
            switch delivery {
            case .pasted:
                return NotchNotice(event: .dictation, title: text.statusPasted, detail: "",
                                   symbol: "checkmark.circle.fill")
            case .copiedSecureInput:
                return NotchNotice(event: .dictation, title: text.statusCopied,
                                   detail: text.noteSecureInput, symbol: "lock.fill")
            case .copiedNoAccessibility:
                return NotchNotice(event: .dictation, title: text.statusCopied,
                                   detail: text.noteNoAccessibility, symbol: "doc.on.clipboard")
            case .copied:
                return NotchNotice(event: .dictation, title: text.statusCopied, detail: "",
                                   symbol: "doc.on.clipboard")
            case .notPasted:
                return NotchNotice(event: .dictation, title: text.statusNotPasted, detail: "",
                                   symbol: "text.cursor", actionTitle: text.copy)
            }
        case let .failed(error):
            return NotchNotice(event: .dictation, title: text.pageTitle, detail: error.message(language),
                               symbol: "exclamationmark.triangle.fill")
        }
    }

    /// The notch shows no words, so a sentence the user has to act on is said
    /// where it can be read. "Nothing heard" needs no action; the notch's
    /// warning symbol is enough.
    static func notification(for phase: DictationService.Phase, language: AppLanguage) -> String? {
        let text = FeatureStrings.dictation(language)
        switch phase {
        case .failed(.noSpeech): return nil
        case let .failed(error): return error.message(language)
        case .finished(.copiedSecureInput): return text.noteSecureInput
        case .finished(.copiedNoAccessibility): return text.noteNoAccessibility
        default: return nil
        }
    }
}
