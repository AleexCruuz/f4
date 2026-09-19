// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import Foundation

/// The whisper.cpp server dictation talks to. Whatever already answers on the
/// configured loopback address is used as it is; otherwise the server Homebrew
/// installed is started there with the chosen model, and stopped once
/// dictation has sat unused long enough to want the memory back.
///
/// State lives on the main thread. The async entry points are main-actor
/// methods so a dictation's requests and the lifecycle never race.
final class DictationEngine {
    enum State: Equatable {
        case stopped
        case starting
        case ready(external: Bool)
        case failed(DictationError)
    }

    /// Called on the main thread whenever `state` changes.
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// A 3 B model and the Whisper weights together are a third of an 8 GB
    /// Mac. The server reloads in about a second, so holding it idle for
    /// longer than a working session buys nothing.
    static let idleTimeout: TimeInterval = 15 * 60

    private var process: Process?
    private var startup: Task<URL, Error>?
    private var idleWork: DispatchWorkItem?
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    // MARK: - Configuration

    func endpoint() throws -> URL {
        let raw = (UserDefaults.standard.string(forKey: DefaultsKey.dictationEndpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try ClipboardAIRunner.validatedEndpoint(
                raw.isEmpty ? DictationEngineSupport.defaultEndpoint : raw)
        } catch {
            throw DictationError.endpointInvalid
        }
    }

    func modelPath() -> String {
        let raw = UserDefaults.standard.string(forKey: DefaultsKey.dictationModelPath) ?? ""
        return DictationEngineSupport.expandedPath(
            raw.isEmpty ? DictationEngineSupport.defaultModelPath : raw,
            home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Whether a server can be found or started at all, without starting it.
    var isConfigured: Bool {
        (try? endpoint()) != nil && (try? locateServer()) != nil && (try? locateModel()) != nil
    }

    /// What Settings can say without starting anything.
    func preflight() {
        guard process == nil, startup == nil else { return }
        if case .ready = state { return }
        do {
            _ = try endpoint()
            _ = try locateServer()
            _ = try locateModel()
            state = .stopped
        } catch let error as DictationError {
            state = .failed(error)
        } catch {
            state = .failed(.engineFailed)
        }
    }

    private func locateServer() throws -> String {
        guard let binary = DictationEngineSupport.serverCandidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { throw DictationError.engineMissing }
        return binary
    }

    private func locateModel() throws -> String {
        let model = modelPath()
        guard FileManager.default.isReadableFile(atPath: model) else {
            throw DictationError.modelMissing(model)
        }
        return model
    }

    // MARK: - Lifecycle

    /// Returns once something is answering, starting the server if needed.
    /// Concurrent callers share one startup.
    @MainActor
    func ensureRunning() async throws -> URL {
        if let startup { return try await startup.value }
        let task = Task { @MainActor [weak self] () throws -> URL in
            guard let self else { throw CancellationError() }
            return try await self.start()
        }
        startup = task
        defer { startup = nil }
        return try await task.value
    }

    @MainActor
    private func start() async throws -> URL {
        let url = try endpoint()
        if await isAnswering(url) {
            state = .ready(external: process == nil)
            touch()
            return url
        }
        do {
            guard let port = DictationEngineSupport.launchPort(for: url) else {
                throw DictationError.engineFailed
            }
            let binary = try locateServer()
            let model = try locateModel()
            state = .starting
            try launch(binary: binary, model: model, port: port)
            // Weights come off disk and the Metal kernels compile: a second
            // warm, several on the first run after a reboot.
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline, process?.isRunning == true {
                try await Task.sleep(nanoseconds: 150_000_000)
                if await isAnswering(url) {
                    state = .ready(external: false)
                    touch()
                    warmUp(url)
                    return url
                }
            }
            stop()
            throw DictationError.engineFailed
        } catch let error as DictationError {
            state = .failed(error)
            throw error
        }
    }

    private func launch(binary: String, model: String, port: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = DictationEngineSupport.serverArguments(model: model, port: port)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // The server sits on the path between letting go and the text
        // appearing. Inheriting a background caller's QoS throttled its Metal
        // shader compile until start-up timed out.
        process.qualityOfService = .userInitiated
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                if self.state == .ready(external: false) { self.state = .stopped }
            }
        }
        do {
            try process.run()
        } catch {
            throw DictationError.engineFailed
        }
        self.process = process
    }

    /// Stops the server this app started. One started by someone else is
    /// left running: it is theirs.
    func stop() {
        idleWork?.cancel()
        idleWork = nil
        if let process {
            self.process = nil
            if process.isRunning { process.terminate() }
        }
        if state != .starting { state = .stopped }
    }

    private func touch() {
        idleWork?.cancel()
        guard process != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    /// The first inference after a cold start compiles the GPU kernels and
    /// took seconds; paying it on a second of silence keeps it off the
    /// user's first sentence.
    private func warmUp(_ url: URL) {
        let boundary = "altf4-warmup"
        var request = URLRequest(url: url.appending(path: "inference"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = DictationEngineSupport.multipartBody(
            boundary: boundary, audio: DictationAudio.wav([Float](repeating: 0, count: DictationAudio.sampleRate)),
            fields: [("response_format", "json"), ("audio_ctx", "512")])
        let session = session
        Task.detached(priority: .utility) { _ = try? await session.upload(for: request, from: body) }
    }

    private func isAnswering(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    // MARK: - Transcription

    @MainActor
    func transcribe(_ samples: [Float], language: String, prompt: String) async throws -> String {
        let url = try await ensureRunning()
        touch()
        var fields: [(String, String)] = [
            ("response_format", "json"),
            ("temperature", "0"),
            ("no_timestamps", "true"),
            ("audio_ctx", String(DictationAudio.encoderContext(sampleCount: samples.count))),
            ("language", language),
        ]
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        let boundary = "altf4-\(UUID().uuidString)"
        let body = DictationEngineSupport.multipartBody(boundary: boundary,
                                                        audio: DictationAudio.wav(samples),
                                                        fields: fields)
        var request = URLRequest(url: url.appending(path: "inference"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw DictationError.transcriptionFailed
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = DictationTranscript.text(fromResponse: data)
        else { throw DictationError.transcriptionFailed }
        return text
    }

    /// A loopback server has nowhere legitimate to redirect to.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
