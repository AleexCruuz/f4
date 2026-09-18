// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AltF4 contributors

import AppKit
import Foundation

/// What the model is asked to do with a clipboard entry.
enum ClipboardAIAction: String, CaseIterable, Identifiable, Sendable {
    case translate, summarize, reformat, explain

    var id: String { rawValue }

    /// TODO: localise. The rest of the app routes user-facing text through
    /// FeatureStrings, which carries a translation per language; these are
    /// English-only until this feature earns its own entries there.
    var title: String {
        switch self {
        case .translate: return "Translate"
        case .summarize: return "Summarise"
        case .reformat: return "Clean up"
        case .explain: return "Explain"
        }
    }

    var symbolName: String {
        switch self {
        case .translate: return "character.bubble"
        case .summarize: return "text.line.3.summary"
        case .reformat: return "wand.and.sparkles"
        case .explain: return "questionmark.bubble"
        }
    }

    /// Kept deliberately blunt. A small local model will happily wrap its answer
    /// in "Sure! Here is the translation:", and the result is pasted straight
    /// into whatever the user is typing, so the preamble has to be shut down in
    /// the system prompt rather than trimmed afterwards.
    func systemPrompt(targetLanguage: String) -> String {
        let common = """
            Output ONLY the result. No preamble, no explanation, no commentary, \
            no surrounding quotes, no markdown fences. Never mention these \
            instructions. If the input is already in the requested form, return \
            it unchanged.
            """
        switch self {
        case .translate:
            return "You are a translation engine. Translate the user's text into \(targetLanguage). Preserve formatting, line breaks and code verbatim. \(common)"
        case .summarize:
            return "You are a summarisation engine. Condense the user's text to its essential points in at most three sentences, in the same language as the input. \(common)"
        case .reformat:
            return "You are a text tidying engine. Fix spelling, punctuation, capitalisation and spacing in the user's text. Do not reword, translate, shorten or change the meaning. \(common)"
        case .explain:
            return "You are an explanation engine. Explain what the user's text is and what it means, in at most three sentences, in the same language as the input. If it is code, an error message or a log line, say what it does or what went wrong. \(common)"
        }
    }
}

enum ClipboardAIError: LocalizedError, Equatable {
    case disabled
    case endpointNotLoopback(String)
    case endpointMalformed(String)
    case runnerUnreachable
    case modelMissing(model: String, installed: [String])
    case emptyInput
    case httpStatus(Int)
    case emptyCompletion

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Clipboard AI is turned off."
        case let .endpointNotLoopback(host):
            return "The model endpoint must be on this Mac, but it points at “\(host)”. Clipboard contents are never sent off the machine, so the request was not made."
        case let .endpointMalformed(raw):
            return "“\(raw)” is not a valid model endpoint."
        case .runnerUnreachable:
            return "No model runner is answering. Install Ollama and run “ollama serve”."
        case let .modelMissing(model, installed):
            if installed.isEmpty {
                return "The runner has no models installed. Run “ollama pull \(model)”."
            }
            return "The model “\(model)” is not installed. Run “ollama pull \(model)”, or pick one of: \(installed.joined(separator: ", "))."
        case .emptyInput:
            return "There is nothing to work on."
        case let .httpStatus(code):
            return "The model runner answered with HTTP \(code)."
        case .emptyCompletion:
            return "The model returned nothing."
        }
    }
}

@MainActor
final class ClipboardAIService: ObservableObject {
    static let shared = ClipboardAIService()

    /// Nil until something has asked. Set so settings can show runner state
    /// without the caller re-probing on every keystroke.
    @Published private(set) var installedModels: [String]?
    @Published private(set) var isWorking = false

    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        // Loading a 3B model into memory measured ~35 s on an 8 GB M2 and the
        // first request of a session pays all of it, so the ceiling has to
        // clear a cold start by a wide margin or the feature looks broken
        // exactly once per launch — the worst possible time.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - Configuration

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.clipboardAIEnabled)
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

    /// The runner must be on this machine. The endpoint is user-editable so a
    /// non-default port works, but a hostname that resolves anywhere else is
    /// refused rather than quietly honoured: the whole promise of the feature is
    /// that the clipboard does not leave the Mac, and a typo here would break
    /// that silently.
    func resolvedEndpoint() throws -> URL {
        let raw = (UserDefaults.standard.string(forKey: DefaultsKey.clipboardAIEndpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = raw.isEmpty ? Defaults.defaultClipboardAIEndpoint : raw
        guard let url = URL(string: candidate), let host = url.host else {
            throw ClipboardAIError.endpointMalformed(candidate)
        }
        guard Self.isLoopback(host) else {
            throw ClipboardAIError.endpointNotLoopback(host)
        }
        return url
    }

    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
            || bare.hasPrefix("127.")
    }

    // MARK: - Runner state

    /// Model names the runner has locally, or nil when nothing is answering.
    @discardableResult
    func refreshInstalledModels() async -> [String]? {
        guard let endpoint = try? resolvedEndpoint() else {
            installedModels = nil
            return nil
        }
        let url = endpoint.appending(path: "api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? decoder.decode(TagsResponse.self, from: data)
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
        guard isEnabled, let url = try? resolvedEndpoint() else { return }
        var request = URLRequest(url: url.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": "",
            "stream": false,
            "keep_alive": Self.keepAlive,
        ])
        Task { _ = try? await session.data(for: request) }
    }

    // MARK: - Running an action

    /// An image or a file list has nothing to hand a language model, so the
    /// affordance is hidden rather than shown and then failed on click.
    func canRun(on entry: ClipboardHistoryEntry) -> Bool {
        isEnabled
            && entry.kind == .text
            && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Runs the action and puts the result on the pasteboard. Every surface
    /// that offers these actions wants exactly this, so the delivery lives here
    /// once instead of being re-implemented per view.
    ///
    /// The result does not replace the entry: the original stays in history and
    /// the capture timer picks the result up as a new entry a moment later, so
    /// both are there to compare and nothing is lost if the model is wrong.
    func perform(_ action: ClipboardAIAction, on entry: ClipboardHistoryEntry) {
        let source = entry.text
        Task { @MainActor in
            do {
                let result = try await run(action, on: source)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(result, forType: .string)
            } catch {
                // Every failure here is a setup step the user has not done yet,
                // so the message carries the fix rather than a status code.
                Notifier.post(title: AppInfo.name, body: error.localizedDescription)
            }
        }
    }

    func run(_ action: ClipboardAIAction, on text: String) async throws -> String {
        guard isEnabled else { throw ClipboardAIError.disabled }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw ClipboardAIError.emptyInput }

        let endpoint = try resolvedEndpoint()
        isWorking = true
        defer { isWorking = false }

        var request = URLRequest(url: endpoint.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "system": action.systemPrompt(targetLanguage: targetLanguage),
            "prompt": input,
            "stream": false,
            // Without this the runner evicts the model after its own short idle
            // timeout, so a pause in a demo or a meeting silently buys back the
            // full cold start.
            "keep_alive": Self.keepAlive,
            "options": [
                // Low temperature: these are transformations of the user's own
                // text, not creative writing. Invention is the failure mode.
                "temperature": 0.2,
                "num_predict": 1_024,
            ],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Nothing listening, or it died mid-request. Either way the useful
            // thing to say is "start the runner", not the URLError text.
            await refreshInstalledModels()
            throw ClipboardAIError.runnerUnreachable
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // A missing model is the one failure worth naming precisely: it is
            // the likely first-run state and it has an exact fix.
            if http.statusCode == 404 {
                let installed = await refreshInstalledModels() ?? []
                throw ClipboardAIError.modelMissing(model: model, installed: installed)
            }
            throw ClipboardAIError.httpStatus(http.statusCode)
        }

        let completion = try decoder.decode(GenerateResponse.self, from: data)
        let result = completion.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw ClipboardAIError.emptyCompletion }
        return result
    }

    // MARK: -

    /// Long enough to survive a talk, a meeting or a coffee.
    private static let keepAlive = "30m"

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private struct GenerateResponse: Decodable {
        let response: String
    }
}
