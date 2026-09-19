// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import AVFoundation
import Foundation

/// The microphone for one dictation. Converts whatever the input device
/// delivers to 16 kHz mono, meters it, and hands over each finished stretch
/// as soon as the speaker pauses. A new recorder is made per dictation, so a
/// device switched since the last one is picked up with its own format.
final class DictationRecorder {
    /// These three are called on the main thread.
    var onLevel: ((Double) -> Void)?
    var onSegment: (([Float]) -> Void)?
    var onInterrupted: (() -> Void)?
    /// Every converted chunk as it arrives, on the recorder's own queue, for
    /// a transcriber that listens live. Set before `start()`.
    var onChunk: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.f4.dictation.recorder", qos: .userInitiated)
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: Double(DictationAudio.sampleRate),
                                       channels: 1, interleaved: false)
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?

    // Owned by `queue`.
    private var samples: [Float] = []
    private var frameCursor = 0
    private var segmenter = DictationSegmenter()

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let target, format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: target)
        else { throw DictationError.microphoneUnavailable }
        converter.downmix = true
        self.converter = converter
        // Small buffers keep the meter within a frame or two of the voice.
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError.microphoneUnavailable
        }
        // The input device changed or vanished mid-sentence: what was heard
        // so far is still worth keeping.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onInterrupted?() }
    }

    /// Stops the microphone and hands back the last stretch, after every
    /// earlier one has already been delivered through `onSegment`.
    ///
    /// The caller lets go of the recorder as soon as it asks to stop, so
    /// everything still in flight holds it strongly until it is delivered.
    func stop(completion: @escaping (_ tail: [Float]?) -> Void) {
        halt()
        queue.async {
            let tail = self.segmenter.finish().flatMap(self.speechSamples(of:))
            DispatchQueue.main.async { completion(tail) }
        }
    }

    func cancel() {
        halt()
        onLevel = nil
        onSegment = nil
    }

    private func halt() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Audio thread

    private func receive(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let target else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
        guard status != .error, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        queue.async { [weak self] in self?.process(chunk) }
    }

    // MARK: - Recorder queue

    private func process(_ chunk: [Float]) {
        onChunk?(chunk)
        samples.append(contentsOf: chunk)
        let level = DictationAudio.meterLevel(rms: DictationAudio.rms(chunk))
        DispatchQueue.main.async { self.onLevel?(level) }
        let length = DictationAudio.frameLength
        while samples.count - frameCursor >= length {
            let rms = DictationAudio.rms(samples[frameCursor ..< frameCursor + length])
            frameCursor += length
            if let segment = segmenter.append(rms: rms), let speech = speechSamples(of: segment) {
                DispatchQueue.main.async { self.onSegment?(speech) }
            }
        }
    }

    private func speechSamples(of segment: DictationSegmenter.Segment) -> [Float]? {
        guard let speech = segment.speech else { return nil }
        let length = DictationAudio.frameLength
        let lower = speech.lowerBound * length
        let upper = min(samples.count, speech.upperBound * length)
        guard lower < upper else { return nil }
        return Array(samples[lower..<upper])
    }
}
