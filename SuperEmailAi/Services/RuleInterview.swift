import Foundation

/// Builds a rule out of a sentence by asking the model one closed question at a time, instead of
/// asking it to compose the whole thing in one go.
///
/// The reason is measured (`DOC/ES/medidas-ia-en-el-aparato.md`, 2026-09-28). Asked for a complete
/// rule, Apple's on-device model answered differently on each run and twice out of three dropped
/// the condition that scoped a delete. Asked to pick one of five words, it was right five times out
/// of five. So the conditions come from the sentence (`RuleSketch`), the model only decides what
/// needs deciding, and `RuleSafety` has the last word.
@MainActor
struct RuleInterview {
    let model: LanguageModel
    let accounts: [String]
    let mailboxes: [String]
    /// Conditions the caller already knows: the account and mailbox the user was looking at when
    /// they typed. They bind the rule (`RuleCondition.isScope`, always ANDed by `RuleEngine`) and
    /// stay out of its name, which says what the rule picks and not where it looks.
    var scope: [RuleCondition] = []

    /// Shown to the model and mapped back here. `move` carries no destination yet: that is a
    /// question of its own.
    private static let actions: [(label: String, action: RuleAction)] = [
        ("mover a una carpeta", .move(account: "", mailbox: "")),
        ("archivar", .archive),
        ("borrar", .delete),
        ("marcar como leído", .markRead),
        ("ponerle una bandera", .flag),
    ]

    func rule(from instruction: String) async throws -> Rule {
        guard model.availability.isReady else { throw ModelError.unavailable(model.availability) }
        let sketch = RuleSketch.read(instruction, accounts: accounts, mailboxes: mailboxes)

        var action = try await askAction(instruction)
        if case .move = action {
            action = .move(account: try account(in: sketch), mailbox: try await mailbox(in: sketch, instruction))
        }

        var chosen = sketch.certain
        for candidate in sketch.uncertain where try await belongs(candidate, instruction) {
            chosen.append(candidate.condition)
        }
        guard !chosen.isEmpty else { throw ModelError.unclearInstruction }

        // Only what the rule picks decides «todas» or «al menos una»; the scope is never one of the
        // alternatives, so it isn't counted here either.
        let matchMode = chosen.count > 1 ? try await askMatchMode(instruction, chosen) : .all
        return try RuleSafety.vet(Rule(name: RuleWording.name(action: action, conditions: chosen),
                                       isEnabled: false, position: 0, matchMode: matchMode,
                                       conditions: scope.filter(\.isScope) + chosen, action: action))
    }

    // MARK: - The questions

    private func askAction(_ instruction: String) async throws -> RuleAction {
        let label = try await model.choose(
            ModelPrompt(role: "Lees una instrucción de un usuario sobre su correo y dices qué hay que hacer.",
                        fields: [.init(name: "instruccion", value: instruction)],
                        task: "¿Qué hay que hacer con los correos que describe la instrucción?"),
            from: Self.actions.map(\.label))
        guard let action = Self.actions.first(where: { $0.label == label })?.action else {
            throw ModelError.badAnswer("«\(label)» no es una acción")
        }
        return action
    }

    /// Asked only when the sentence didn't name a folder the user really has.
    private func mailbox(in sketch: RuleSketch, _ instruction: String) async throws -> String {
        if sketch.mailboxes.count == 1 { return sketch.mailboxes[0] }
        guard !mailboxes.isEmpty else { throw ModelError.unclearInstruction }
        if mailboxes.count == 1 { return mailboxes[0] }
        return try await model.choose(
            ModelPrompt(role: "Lees una instrucción de un usuario sobre su correo y eliges una carpeta.",
                        fields: [.init(name: "instruccion", value: instruction)],
                        task: "¿A qué carpeta hay que mover esos correos?"),
            from: mailboxes)
    }

    /// Never asked. The instruction almost never says which account a folder belongs to, and a
    /// model with nothing to go on would be guessing where mail ends up; the user settles it.
    private func account(in sketch: RuleSketch) throws -> String {
        if sketch.accounts.count == 1 { return sketch.accounts[0] }
        if accounts.count == 1 { return accounts[0] }
        throw ModelError.missingAccount(mailbox: sketch.mailboxes.first ?? "")
    }

    private func belongs(_ candidate: RuleSketch.Candidate, _ instruction: String) async throws -> Bool {
        let answer = try await model.choose(
            ModelPrompt(role: "Lees una instrucción de un usuario sobre su correo y respondes sí o no.",
                        fields: [.init(name: "instruccion", value: instruction)],
                        task: "¿La instrucción pide que la regla se limite a los correos en los que "
                            + "\(RuleWording.describe(candidate.condition))?"),
            from: ["sí", "no"])
        return answer == "sí"
    }

    private func askMatchMode(_ instruction: String, _ conditions: [RuleCondition]) async throws -> Rule.MatchMode {
        let answer = try await model.choose(
            ModelPrompt(role: "Lees una instrucción de un usuario sobre su correo y respondes con una palabra.",
                        fields: [.init(name: "instruccion", value: instruction),
                                 .init(name: "condiciones", value: conditions.map(RuleWording.describe)
                                        .joined(separator: "\n"))],
                        task: "¿La regla debe elegir los correos que cumplan todas las condiciones o "
                            + "los que cumplan al menos una?"),
            from: ["todas", "al menos una"])
        return answer == "todas" ? .all : .any
    }
}

/// The last word on what the AI proposes. It does not touch a rule the user wrote by hand: that one
/// is their business. A rule a model composed is not trusted this far.
enum RuleSafety {
    static func vet(_ rule: Rule) throws -> Rule {
        var vetted = rule

        // «Marca como leídos los que ya están leídos» is not a preference, it's a contradiction: the
        // rule would do nothing at all. The model produced exactly this in the bench.
        if rule.action == .markRead {
            vetted.conditions.removeAll { $0 == .isRead(true) }
            vetted.name = RuleWording.name(action: vetted.action, conditions: vetted.conditions)
        }

        // Only what the rule *picks* counts here. The account and the mailbox say where it looks,
        // and a delete that looks somewhere and picks by the clock alone is the dangerous rule with
        // two extra conditions on it.
        let picks = vetted.conditions.filter { !$0.isScope }
        guard !picks.isEmpty else { throw ModelError.unclearInstruction }

        // Measured: «borra los boletines de más de 30 días» came back as just «más de 30 días» in
        // two runs out of three, and «al menos una» does the same damage with the newsletter
        // condition still in place.
        if rule.action == .delete {
            if picks.allSatisfy(\.looksOnlyAtTheClock) {
                throw ModelError.tooBroad("borraría cualquier correo por su antigüedad, sin mirar de quién es")
            }
            if vetted.matchMode == .any, picks.contains(where: \.looksOnlyAtTheClock) {
                throw ModelError.tooBroad("con «al menos una» borraría cualquier correo antiguo")
            }
        }

        if case .move(let account, let mailbox) = vetted.action, account.isEmpty || mailbox.isEmpty {
            throw ModelError.missingAccount(mailbox: mailbox)
        }
        return vetted
    }
}
