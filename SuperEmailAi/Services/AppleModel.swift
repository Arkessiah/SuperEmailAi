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

    /// Guided generation needs a *struct* to aim at. A bare `@Generable enum` looks like the
    /// obvious fit and is a trap: measured 2026-09-28, classifying six mails straight into an enum
    /// got 0 of 6 right, answering the first case almost every time. The same six, through this
    /// wrapper with the options named in the task, got 5 of 6 — and the miss was arguable.
    @Generable struct Choice {
        @Guide(description: "Una de las opciones dadas, escrita tal cual") var opcion: String
    }

    static func choose(_ prompt: ModelPrompt, from options: [String]) async throws -> String {
        var asked = prompt
        asked.task = "\(prompt.task)\n\nElige una de estas opciones, tal cual: \(options.joined(separator: ", "))."
        let session = LanguageModelSession(instructions: prompt.role)
        let answer: String
        do {
            answer = try await session.respond(to: asked.body, generating: Choice.self).content.opcion
        } catch let error as LanguageModelSession.GenerationError {
            throw translate(error)
        } catch {
            throw ModelError.engineFailed(error.localizedDescription)
        }
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
