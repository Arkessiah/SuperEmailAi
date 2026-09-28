import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (macOS 26). Nothing leaves the Mac, there is no key to keep and no
/// bill to pay, which is the whole reason it comes first. On an older macOS it simply reports
/// `.noEngine` and the AI parts of the app stay hidden.
struct AppleModel: LanguageModel {
    var availability: ModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return AppleEngine.availability }
        #endif
        return .noEngine
    }

    func answer(_ prompt: ModelPrompt) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return try await AppleEngine.answer(prompt) }
        #endif
        throw ModelError.unavailable(.noEngine)
    }

    /// Asks for one of `options` and holds the model to it: an answer outside the list is thrown
    /// away rather than passed on, whatever the engine felt like saying.
    func choose(_ prompt: ModelPrompt, from options: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return try await AppleEngine.choose(prompt, from: options) }
        #endif
        throw ModelError.unavailable(.noEngine)
    }

    func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { AppleEngine.prewarm() }
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private enum AppleEngine {
    static var availability: ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: .deviceNotEligible
            case .appleIntelligenceNotEnabled: .notEnabled
            case .modelNotReady: .notReady
            @unknown default: .notReady
            }
        }
    }

    /// A fresh session per mail, on purpose: a session keeps its transcript, so reusing one would
    /// spend the context window on old mail and let one message colour the answer about the next.
    static func answer(_ prompt: ModelPrompt) async throws -> String {
        let session = LanguageModelSession(instructions: prompt.role)
        do {
            return try await session.respond(to: prompt.body).content
        } catch let error as LanguageModelSession.GenerationError {
            throw translate(error)
        } catch {
            throw ModelError.engineFailed(error.localizedDescription)
        }
    }

    /// The list is turned into a schema at runtime, so the engine cannot answer outside it — it is
    /// not asked nicely and checked afterwards, it is decoded into the list.
    ///
    /// Two dead ends, both measured on 2026-09-28. Asking in plain text and parsing the reply got
    /// 4 of 6 mails classified right, and one of the misses was only a missing accent. Aiming at a
    /// bare `@Generable enum` got **0 of 6**: it answered the first case of the enum almost every
    /// time. `@Generable` also needs a macro the Command Line Tools toolchain doesn't carry, which
    /// breaks a plain `swift build`; this way there is no macro at all.
    static func choose(_ prompt: ModelPrompt, from options: [String]) async throws -> String {
        guard !options.isEmpty else { throw ModelError.badAnswer("sin opciones que elegir") }
        var asked = prompt
        asked.task = "\(prompt.task)\n\nElige una de estas opciones: \(options.joined(separator: ", "))."
        let answer: String
        do {
            let list = DynamicGenerationSchema(name: "Eleccion", anyOf: options)
            let wrapper = DynamicGenerationSchema(
                name: "Respuesta",
                properties: [.init(name: "opcion", description: "La opción elegida", schema: list)])
            let schema = try GenerationSchema(root: wrapper, dependencies: [])
            let session = LanguageModelSession(instructions: prompt.role)
            let content = try await session.respond(to: asked.body, schema: schema).content
            answer = try content.value(String.self, forProperty: "opcion")
        } catch let error as LanguageModelSession.GenerationError {
            throw translate(error)
        } catch {
            throw ModelError.engineFailed(error.localizedDescription)
        }
        // The schema should make this impossible; it stays because a rule built on a wrong answer
        // costs far more than a thrown error.
        guard let match = ModelChoice.match(answer, in: options) else {
            throw ModelError.badAnswer("«\(answer)» no está entre las opciones")
        }
        return match
    }

    static func translate(_ error: LanguageModelSession.GenerationError) -> ModelError {
        switch error {
        case .exceededContextWindowSize: .tooLong
        case .guardrailViolation: .refused
        case .unsupportedLanguageOrLocale: .engineFailed("el idioma no está soportado")
        default: .engineFailed(error.localizedDescription)
        }
    }

    /// Loading the model is what costs the seconds, not the answer, so it's worth paying for it
    /// while the user is still reading the mail.
    static func prewarm() {
        guard SystemLanguageModel.default.availability == .available else { return }
        LanguageModelSession().prewarm()
    }
}
#endif

/// The engine the app uses. MLX would slot in here, and only here, if macOS 14 and 15 ever turn
/// out to matter enough to pay for it (decision pending, ARK-206).
enum ModelEngine {
    static func best() -> LanguageModel { AppleModel() }
}
