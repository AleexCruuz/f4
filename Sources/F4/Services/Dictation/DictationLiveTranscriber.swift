// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import AVFoundation
import Foundation
// The macOS 26 SDK brings SpeechAnalyzer and Foundation Models together; an
// older SDK (CI's 15.2) builds without both, and dictation falls back to
// whisper.cpp and Ollama.
#if canImport(FoundationModels)
import FoundationModels
import Speech

/// Apple's on-device dictation model, fed while the user speaks. Volatile
/// results refine as more audio arrives and settle into finalized text, so
/// by the time the key is released the transcript is already there.
@available(macOS 26.0, *)
final class DictationLiveTranscriber {
    /// Finalized text, then the still-changing tail. Main thread.
    var onText: ((_ finalized: String, _ volatile: String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    // Audio arrives on the recorder's queue; these belong to it.
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending: [[Float]] = []
    private var closed = false

    static func locale(for language: String) async -> Locale? {
        let wanted = language == "auto" ? Locale.current : Locale(identifier: language)
        return await DictationTranscriber.supportedLocale(equivalentTo: wanted)
    }

    /// Whether this Mac has the model for `language` without a download.
    static func isInstalled(language: String) async -> Bool {
        guard let locale = await locale(for: language) else { return false }
        return await AssetInventory.status(forModules: [makeTranscriber(locale)]) == .installed
    }

    /// Volatile results for the live text, punctuation because the text is
    /// pasted, frequent finalization so the settled part keeps up.
    private static func makeTranscriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults, .frequentFinalization],
                             attributeOptions: [])
    }

    @MainActor
    func start(language: String, vocabulary: [String]) async throws {
        guard let locale = await Self.locale(for: language) else { throw DictationError.engineMissing }
        let transcriber = Self.makeTranscriber(locale)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.continuation = continuation
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalized = DictationTranscript.joined([self.finalized, text])
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    self.onText?(self.finalized, self.volatile)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        ready(format: best)
    }

    /// 16 kHz mono samples from the recorder, in order. Audio that arrives
    /// before the analyzer is up is held and sent the moment it is.
    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        guard format != nil else {
            pending.append(samples)
            return
        }
        send(samples)
    }

    private func ready(format best: AVAudioFormat?) {
        lock.lock()
        defer { lock.unlock() }
        let source = Self.sourceFormat
        let target = best ?? source
        format = target
        converter = target == source ? nil : AVAudioConverter(from: source, to: target)
        pending.forEach(send)
        pending = []
    }

    private static let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: Double(DictationAudio.sampleRate),
                                                    channels: 1, interleaved: false)!

    /// Called with the lock held.
    private func send(_ samples: [Float]) {
        guard let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.sourceFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        guard let converter else {
            continuation?.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = format.sampleRate / Self.sourceFormat.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 64)
        else { return }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation?.yield(AnalyzerInput(buffer: output))
    }

    /// Everything said, once the model has settled its last words.
    @MainActor
    func finish() async -> String {
        // A last word that runs into the end of the input is dropped; a
        // moment of silence lets the model settle it.
        append([Float](repeating: 0, count: DictationAudio.sampleRate * 2 / 5))
        lock.withLock { closed = true }
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        return DictationTranscript.joined([finalized, volatile])
    }

    func cancel() {
        lock.withLock { closed = true }
        continuation?.finish()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
    }
}

/// Apple's on-device language model for the cleanup: already in memory on a
/// Mac with Apple Intelligence, so it answers in about a second where a 3 B
/// model beside Whisper took six or more on 8 GB.
@available(macOS 26.0, *)
enum DictationAppleModel {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private static var warm: LanguageModelSession?

    /// Loads the model while the user is still speaking.
    @MainActor
    static func prewarm() {
        guard isAvailable else { return }
        let session = LanguageModelSession()
        session.prewarm()
        warm = session
    }

    @MainActor
    static func polish(_ text: String, instructions: String, prompt: String) async -> String? {
        guard isAvailable else { return nil }
        warm = nil
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0)
        return try? await session.respond(to: prompt, options: options).content
    }
}
#endif
