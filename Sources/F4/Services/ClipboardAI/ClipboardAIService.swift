// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 F4 contributors

import AppKit
import Foundation

@MainActor
final class ClipboardAIService: ObservableObject {
    static let shared = ClipboardAIService()

    /// One action applied to one entry, from the click to whatever the user
    /// does with the answer. The panel renders this and nothing else, so what
    /// is on screen and what the request is doing cannot drift apart.
    struct Run: Identifiable, Equatable {
        let id: UUID
        let action: ClipboardAIAction
        let subject: ClipboardAISubject
        /// The sanitised text actually sent, not the raw entry: the page shows
        /// what the model saw, so a result that looks wrong can be read against
        /// its real input.
        let source: String
        var output: String
        var phase: Phase
        /// When the request left, so the wait for a cold model can be shown.
        let startedAt: Date

        var module: NotchModule { subject.module }
        var isBusy: Bool { phase == .loading || phase == .streaming }
        /// Replacing the saved entry only makes sense for the actions that hand
        /// back a version of the text rather than a statement about it.
        var canReplaceEntry: Bool { phase == .finished && action.isRewrite }
    }

    enum Phase: Equatable {
        /// Weights are being loaded; nothing has come back yet. A cold start is
        /// tens of seconds, so this is a state of its own rather than an
        /// indistinguishable early part of streaming.
        case loading
        case streaming
        case finished
        case failed(ClipboardAIError)
    }

    @Published private(set) var run: Run?
    /// Nil until something has asked, and nil again whenever nothing answers.
    @Published private(set) var installedModels: [String]?

    private let session: URLSession
    private var task: Task<Void, Never>?
    /// False when the run started with no panel able to show it. The answer
    /// then goes where it used to: onto the pasteboard, with a notification.
    private var isPresented = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        // The ceiling is per chunk once the answer is streaming, but the first
        // chunk of a session waits for the whole model load: ~35 s for a 3B on
        // an 8 GB M2. A tighter limit would fail exactly once per launch, at
        // the worst possible moment.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        // A local runner cannot legitimately redirect anywhere, and following
        // one would be the one way a loopback-checked endpoint still reaches
        // the network.
        session = URLSession(configuration: configuration,
                             delegate: NoRedirects(), delegateQueue: nil)
    }

    // MARK: - Configuration

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.clipboardAIEnabled)
    }

    var refusesSensitiveInput: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.clipboardAIBlockSensitive)
    }

    var model: String {
        let stored = UserDefaults.standard.string(forKey: DefaultsKey.clipboardAIModel) ?? ""
        return stored.isEmpty ? Defaults.defaultClipboardAIModel : stored
    }

    /// Empty means "whatever this Mac is set to", which is what someone
    /// reaching for translate almost always wants.
    var targetLanguage: String {
        let stored = (UserDefaults.standard.string(forKey: DefaultsKey.clipboardAITargetLanguage) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        let code = Locale.preferredLanguages.first ?? "en"
        return Locale(identifier: "en").localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forIdentifier: code)
            ?? "English"
    }

    func resolvedEndpoint() throws -> URL {
        let raw = (UserDefaults.standard.string(forKey: DefaultsKey.clipboardAIEndpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try ClipboardAIRunner.validatedEndpoint(
            raw.isEmpty ? Defaults.defaultClipboardAIEndpoint : raw)
    }

    // MARK: - Runner state

    /// Model names the runner has locally, or nil when nothing is answering.
    @discardableResult
    func refreshInstalledModels() async -> [String]? {
        guard let endpoint = try? resolvedEndpoint() else {
            installedModels = nil
            return nil
        }
        var request = URLRequest(url: endpoint.appending(path: "api/tags"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else {
            installedModels = nil
            return nil
        }
        let names = list.models.map(\.name).sorted()
        installedModels = names
        return names
    }

    /// Fires a zero-token request so the weights are resident before the user
    /// asks for anything real. Cold is ~35 s, warm is ~2 s; without this the
    /// first action of the day always pays the difference.
    func warmUp() {
        guard isEnabled, ClipboardAIRunner.isValidModelName(model),
              let url = try? resolvedEndpoint() else { return }
        var request = URLRequest(url: url.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": "", "stream": false, "keep_alive": Self.keepAlive,
        ])
        Task { _ = try? await session.data(for: request) }
    }

    // MARK: - Offering the actions

    /// An image or a file list has nothing to hand a language model, so the
    /// affordance is hidden rather than shown and then failed on click.
    func canRun(on entry: ClipboardHistoryEntry) -> Bool {
        isEnabled
            && entry.kind == .text
            && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func canRun(on record: DictationRecord) -> Bool {
        isEnabled && !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Running an action

    /// Starts `action` on `entry` and shows it wherever it can be watched.
    ///
    /// Only one run exists at a time. A second click replaces the first rather
    /// than queueing: the panel has one result page, and a queue behind it
    /// would finish into a page nobody is looking at.
    func start(_ action: ClipboardAIAction, on entry: ClipboardHistoryEntry) {
        start(action, text: entry.text, subject: .clipboard(entry.id))
    }

    func start(_ action: ClipboardAIAction, on record: DictationRecord) {
        start(action, text: record.text, subject: .dictation(record.id))
    }

    private func start(_ action: ClipboardAIAction, text: String, subject: ClipboardAISubject) {
        cancel()
        let language = L10n.shared.language
        let input: String
        do {
            guard isEnabled else { throw ClipboardAIError.disabled }
            input = try ClipboardAIInput.prepare(text, for: action,
                                                 refusingSensitive: refusesSensitiveInput)
        } catch let error as ClipboardAIError {
            // Refused before a request exists. There is no page worth opening
            // for it, so it is said where the click happened.
            Notifier.post(title: AppInfo.name, body: error.message(language))
            return
        } catch {
            return
        }

        let id = UUID()
        run = Run(id: id, action: action, subject: subject,
                  source: input, output: "", phase: .loading, startedAt: Date())
        isPresented = NotchService.shared.showClipboardAI(in: subject.module)
        task = Task { [weak self] in await self?.stream(action: action, input: input, runID: id) }
    }

    /// Stops the run and keeps the page, so the part that did arrive is still
    /// readable and a retry is one click away.
    func cancel() {
        task?.cancel()
        task = nil
        guard var current = run, current.isBusy else { return }
        current.phase = .failed(.cancelled)
        run = current
    }

    func retry() {
        guard let current = run else { return }
        cancel()
        let id = UUID()
        run = Run(id: id, action: current.action, subject: current.subject,
                  source: current.source, output: "", phase: .loading, startedAt: Date())
        task = Task { [weak self] in
            await self?.stream(action: current.action, input: current.source, runID: id)
        }
    }

    func dismiss() {
        cancel()
        run = nil
    }

    /// The result reaches the pasteboard only when the user says so. The
    /// original entry is untouched either way, so a wrong answer costs a click
    /// rather than the text it replaced.
    func copyResult() {
        guard let current = run, current.phase == .finished, !current.output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(current.output, forType: .string)
    }

    /// Looked up rather than carried in the run: the entry can be edited,
    /// pinned or dropped from history while the model is still writing, and
    /// the copy taken at the click would not know.
    func replaceEntry() {
        guard let current = run, current.canReplaceEntry else { return }
        switch current.subject {
        case .clipboard(let id):
            guard let entry = ClipboardHistoryService.shared.entries.first(where: { $0.id == id }) else { return }
            ClipboardHistoryService.shared.updateText(entry, to: current.output)
        case .dictation(let id):
            DictationHistoryService.shared.updateText(of: id, to: current.output)
        }
    }

    // MARK: - The request

    /// A cancelled request can still be unwinding when its replacement starts,
    /// so everything it publishes names the run it belongs to.
    private func stream(action: ClipboardAIAction, input: String, runID: UUID) async {
        let language = L10n.shared.language
        let nonce = ClipboardAIPrompt.nonce()
        do {
            guard ClipboardAIRunner.isValidModelName(model) else {
                throw ClipboardAIError.modelNameInvalid(model)
            }
            let endpoint = try resolvedEndpoint()
            let raw = try await collect(action: action, input: input, nonce: nonce,
                                        endpoint: endpoint, runID: runID)
            try Task.checkCancellation()
            let cleaned = try ClipboardAIOutput.clean(raw, action: action,
                                                      input: input, nonce: nonce)
            finish(with: cleaned, language: language, runID: runID)
        } catch is CancellationError {
            // cancel() already wrote the phase, and it holds the partial text.
        } catch let error as ClipboardAIError {
            fail(with: error, language: language, runID: runID)
        } catch {
            fail(with: .runnerUnreachable, language: language, runID: runID)
        }
    }

    /// Streams the answer, publishing it as it arrives. Returns the raw text;
    /// every check on it happens afterwards, on the whole thing.
    private func collect(action: ClipboardAIAction, input: String, nonce: String,
                         endpoint: URL, runID: UUID) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "system": ClipboardAIPrompt.system(for: action, nonce: nonce,
                                               targetLanguage: targetLanguage),
            "prompt": ClipboardAIPrompt.userMessage(input, nonce: nonce),
            "stream": true,
            // Without this the runner evicts the model after its own short idle
            // timeout, so a pause in a demo or a meeting silently buys back the
            // full cold start.
            "keep_alive": Self.keepAlive,
            "options": [
                "temperature": action.temperature,
                "num_predict": action.tokenBudget(inputCharacters: input.count),
            ],
        ])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            // URLSession reports a cancelled task as its own URLError, not as
            // a CancellationError; either way the runner was never the problem.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Nothing listening, or it died before answering. Either way the
            // useful thing to say is "start the runner", not the URLError text.
            await refreshInstalledModels()
            throw ClipboardAIError.runnerUnreachable
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // A missing model is the one failure worth naming precisely: it is
            // the likely first-run state and it has an exact fix.
            if http.statusCode == 404 {
                throw ClipboardAIError.modelMissing(model: model,
                                                    installed: await refreshInstalledModels() ?? [])
            }
            throw ClipboardAIError.httpStatus(http.statusCode)
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let chunk = ClipboardAIRunner.streamedChunk(from: line) else { continue }
            accumulated += chunk.text
            // A runner that never stops is a real failure mode, and a streamed
            // one fills memory while it happens. Stop reading rather than wait
            // for a token budget the model may be ignoring.
            guard accumulated.count <= ClipboardAIOutput.characterLimit else {
                throw ClipboardAIError.outputTooLong(limit: ClipboardAIOutput.characterLimit)
            }
            publishPartial(accumulated, runID: runID)
            if chunk.done { break }
        }
        return accumulated
    }

    // MARK: - Publishing

    private func publishPartial(_ text: String, runID: UUID) {
        guard var current = run, current.id == runID, current.isBusy else { return }
        current.output = text
        current.phase = .streaming
        run = current
    }

    private func finish(with output: String, language: AppLanguage, runID: UUID) {
        guard var current = run, current.id == runID, current.isBusy else { return }
        current.output = output
        current.phase = .finished
        run = current
        guard !isPresented else { return }
        // Nothing could show it, so it behaves the way it did before there was
        // a page: on the pasteboard, with a line saying so.
        copyResult()
        Notifier.post(title: AppInfo.name,
                      body: FeatureStrings.clipboardAI(language).copied)
    }

    private func fail(with error: ClipboardAIError, language: AppLanguage, runID: UUID) {
        guard var current = run, current.id == runID, current.isBusy else { return }
        current.phase = .failed(error)
        run = current
        guard !isPresented else { return }
        Notifier.post(title: AppInfo.name, body: error.message(language))
    }

    // MARK: -

    /// Long enough to survive a talk, a meeting or a coffee.
    private static let keepAlive = "30m"

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
