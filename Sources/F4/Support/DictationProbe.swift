// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

#if F4_DEVELOPMENT
import AVFoundation
import Foundation

/// Runs one audio file through dictation's real pipeline without a window or
/// a microphone: the server start-up, the cuts at pauses, each transcription
/// in order, the fast path and the cleanup, with the time each one took.
///
///     build/F4Developer --dictation-probe clip.wav [--language es]
///         [--polish off|smart|always] [--vocabulary "Ollama, F4"]
enum DictationProbe {
    static func runAndExit() -> Never {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value(after: "--dictation-probe") else {
            fputs("usage: --dictation-probe <audio file>\n", stderr)
            exit(2)
        }
        Task { @MainActor in
            let status = await run(path: path,
                                   language: value(after: "--language"),
                                   polish: value(after: "--polish").map { DictationPolishMode.sanitized($0) },
                                   vocabulary: value(after: "--vocabulary"))
            DictationService.shared.engine.stop()
            exit(status)
        }
        dispatchMain()
    }

    /// A command line reads a point, whatever region the Mac is set to.
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let arguments = CommandLine.arguments

    @MainActor
    private static func run(path: String, language override: String?, polish: DictationPolishMode?,
                            vocabulary rawVocabulary: String?) async -> Int32 {
        guard let samples = load(URL(fileURLWithPath: path)) else {
            print("DICTATION PROBE FAILED: cannot read \(path)")
            return 1
        }
        let service = DictationService.shared
        let language = override.map { DictationLanguage.code(setting: $0, preferredLanguages: []) } ?? service.language
        let vocabulary = rawVocabulary.map(DictationTranscript.vocabulary(from:)) ?? service.vocabulary
        let mode = polish ?? service.polishMode
        print(String(format: "audio: %.2f s, language: %@, polish: %@, vocabulary: %@", locale: posix,
                     Double(samples.count) / Double(DictationAudio.sampleRate), language, mode.rawValue,
                     vocabulary.joined(separator: ", ")))

        let clock = ContinuousClock()
        let started = clock.now
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), !arguments.contains("--whisper") {
            let live = DictationLiveTranscriber()
            do {
                try await live.start(language: language, vocabulary: vocabulary)
            } catch {
                print("DICTATION PROBE FAILED: live engine \(error)")
                return 1
            }
            print("live engine up after \(started.duration(to: clock.now))")
            // The microphone's pace is ~10 ms chunks; the file goes in as fast
            // as the model takes it, then "release" is timed on its own.
            stride(from: 0, to: samples.count, by: 160).forEach {
                live.append(Array(samples[$0 ..< min(samples.count, $0 + 160)]))
            }
            let released = clock.now
            let raw = await live.finish()
            print("live: \(raw) (ready \(released.duration(to: clock.now)) after release)")
            var text = DictationTranscript.tidy(raw, language: language, vocabulary: vocabulary)
            if mode == .always || (mode == .smart && DictationTranscript.needsPolish(text, language: language)) {
                let begun = clock.now
                if let polished = await service.polish(text, language: language, vocabulary: vocabulary) {
                    text = DictationTranscript.applyingVocabulary(polished, vocabulary)
                }
                print("polish (\(begun.duration(to: clock.now)))")
            }
            print("DICTATION PROBE OK in \(started.duration(to: clock.now)): \(text)")
            return 0
        }
        #endif
        do {
            _ = try await service.engine.ensureRunning()
        } catch {
            print("DICTATION PROBE FAILED: engine \(error)")
            return 1
        }
        print("engine: \(service.engine.state) after \(started.duration(to: clock.now))")

        var segmenter = DictationSegmenter()
        var stretches: [[Float]] = []
        let length = DictationAudio.frameLength
        func slice(_ segment: DictationSegmenter.Segment) -> [Float]? {
            guard let speech = segment.speech else { return nil }
            return Array(samples[speech.lowerBound * length ..< min(samples.count, speech.upperBound * length)])
        }
        var cursor = 0
        while cursor + length <= samples.count {
            if let segment = segmenter.append(rms: DictationAudio.rms(samples[cursor ..< cursor + length])),
               let stretch = slice(segment) {
                stretches.append(stretch)
            }
            cursor += length
        }
        if let tail = segmenter.finish().flatMap(slice) { stretches.append(tail) }
        guard !stretches.isEmpty else {
            print("DICTATION PROBE: no speech heard")
            return 1
        }

        var parts: [String] = []
        for (index, stretch) in stretches.enumerated() {
            let prompt = DictationTranscript.whisperPrompt(vocabulary: vocabulary,
                                                           previous: DictationTranscript.joined(parts))
            let begun = clock.now
            do {
                let text = try await service.engine.transcribe(stretch, language: language, prompt: prompt)
                let dropped = DictationTranscript.isHallucination(text)
                if !dropped { parts.append(text) }
                print(String(format: "stretch %d: %.2f s audio, ctx %d, ", locale: posix, index + 1,
                             Double(stretch.count) / Double(DictationAudio.sampleRate),
                             DictationAudio.encoderContext(sampleCount: stretch.count))
                      + "\(begun.duration(to: clock.now))\(dropped ? " (dropped)" : ""): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch {
                print("DICTATION PROBE FAILED: stretch \(index + 1) \(error)")
                return 1
            }
        }

        var text = DictationTranscript.tidy(DictationTranscript.joined(parts), language: language,
                                            vocabulary: vocabulary)
        print("tidy: \(text)")
        let wantsPolish = mode == .always
            || (mode == .smart && DictationTranscript.needsPolish(text, language: language))
        if wantsPolish {
            let begun = clock.now
            if let polished = await service.polish(text, language: language, vocabulary: vocabulary) {
                text = DictationTranscript.applyingVocabulary(polished, vocabulary)
                print("polish (\(begun.duration(to: clock.now))): \(text)")
            } else {
                print("polish (\(begun.duration(to: clock.now))): kept the tidied text")
            }
        } else {
            print("polish: skipped (\(mode.rawValue))")
        }
        print("DICTATION PROBE OK in \(started.duration(to: clock.now)): \(text)")
        return 0
    }

    /// Any file AVFoundation can read, converted the way the recorder
    /// converts the microphone.
    private static func load(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(DictationAudio.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil
        else { return nil }
        converter.downmix = true
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024)
        else { return nil }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
#endif
