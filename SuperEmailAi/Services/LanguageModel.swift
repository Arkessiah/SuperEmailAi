import Foundation

/// Why the model can't be used, in the words the screen will show.
enum ModelAvailability: Equatable {
    case ready
    case deviceNotEligible   // this Mac can't run it: permanent, hide the feature
    case notEnabled          // Apple Intelligence is off: the user can fix it
    case notReady            // still preparing itself: temporary, try later
    case noEngine            // built without an engine (older macOS)

    var isReady: Bool { self == .ready }

    var message: String {
        switch self {
        case .ready: "Lista"
        case .deviceNotEligible: "Este Mac no puede usar la IA de Apple"
        case .notEnabled: "Activa Apple Intelligence en Ajustes para usar la IA"
        case .notReady: "La IA de Apple todavía se está preparando; inténtalo en un rato"
        case .noEngine: "Esta versión de macOS no trae la IA de Apple"
        }
    }
}

/// A prompt: the app's instructions and the mail **as data**, never mixed into them. The mail is
/// untrusted text, so every field goes wrapped and escaped (ARK-207).
struct ModelPrompt: Equatable {
    var instructions: String
    var fields: [Field]

    struct Field: Equatable {
        var name: String
        var value: String
    }

    init(_ instructions: String, _ fields: [Field] = []) {
        self.instructions = instructions
        self.fields = fields
    }

    var text: String {
        ([instructions] + fields.map { ModelText.promptField($0.name, $0.value) }).joined(separator: "\n\n")
    }
}

/// What the app asks a language model, whatever the engine underneath: Apple's on-device model
/// today, another one (MLX) later if it's ever needed. The engine never acts: it answers, and
/// Swift validates the answer before anything touches Mail.
protocol LanguageModel: Sendable {
    var availability: ModelAvailability { get }

    /// Free-form answer for a task (summary, draft…).
    func answer(_ prompt: ModelPrompt) async throws -> String

    /// One option from a closed list. The engine must not invent anything outside it.
    func choose(_ prompt: ModelPrompt, from options: [String]) async throws -> String
}

enum ModelError: LocalizedError, Equatable {
    case unavailable(ModelAvailability)
    case badAnswer(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): why.message
        case .badAnswer(let detail): "La IA respondió algo que no se entiende: \(detail)"
        }
    }
}
