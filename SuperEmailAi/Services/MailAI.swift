import Foundation

/// The only shape the model may answer with when asked for a rule. Anything outside this is
/// rejected: the model proposes, `MailAI.rule(from:)` decides.
struct RuleDraft: Codable, Equatable {
    struct Condition: Codable, Equatable {
        var tipo: String
        var texto: String?
        var numero: Int?
        var valor: Bool?
    }

    var nombre: String
    var coinciden: String          // "todas" | "alguna"
    var condiciones: [Condition]
    var accion: String             // mover | archivar | borrar | marcarLeido | bandera
    var cuenta: String?
    var buzon: String?
}

/// The app's AI tasks on top of whatever engine is available. Everything the model reads is
/// prepared first (ARK-207) and everything it answers is validated here: nothing the model says
/// reaches Mail without passing through Swift.
@MainActor
final class MailAI: ObservableObject {
    @Published private(set) var availability: ModelAvailability

    private let model: LanguageModel

    init(model: LanguageModel) {
        self.model = model
        availability = model.availability
    }

    func refreshAvailability() { availability = model.availability }

    // MARK: - Reading help

    /// Two lines about a mail, for deciding whether to open it now.
    func summary(subject: String, sender: String, html: String?, plain: String) async throws -> String {
        let prompt = ModelPrompt(
            role: "Eres un ayudante que resume correos. Respondes siempre en español.",
            fields: fields(subject: subject, sender: sender,
                           body: ModelText.prepare(html: html, plain: plain, for: .summarize)),
            task: """
            Resume en español el correo de arriba, en dos frases como mucho, para alguien que decide \
            si abrirlo ahora. Di qué piden y para cuándo, si el correo lo dice. No inventes fechas, \
            importes ni nombres que no estén en él.
            """)
        return try await text(of: prompt)
    }

    /// A reply draft. Never sent: it goes to the editor for the user to change.
    func draftReply(subject: String, sender: String, html: String?, plain: String, intent: String) async throws -> String {
        var parts = fields(subject: subject, sender: sender,
                           body: ModelText.prepare(html: html, plain: plain, for: .draftReply))
        parts.append(.init(name: "que_quiero_decir", value: intent))
        let prompt = ModelPrompt(
            role: "Eres un ayudante que escribe borradores de respuesta a correos. Escribes siempre en español.",
            fields: parts,
            task: """
            Escribe en español un borrador de respuesta al correo de arriba, diciendo lo que pide \
            «que_quiero_decir». Usa el mismo trato (tú o usted) que use el correo. Sé breve y concreto, \
            y no prometas nada que no esté ahí. Devuelve solo el texto del correo, sin asunto ni firma.
            """)
        return try await text(of: prompt)
    }

    // MARK: - Rules in plain language (ARK-208)

    /// Turns «mueve a Facturas los correos de mi gestoría» into a rule the user reviews in the
    /// editor before it ever runs, by asking one closed question at a time (`RuleInterview`).
    func rule(from instruction: String, accounts: [String], mailboxes: [String]) async throws -> Rule {
        try await RuleInterview(model: model, accounts: accounts, mailboxes: mailboxes).rule(from: instruction)
    }

    /// The first attempt, kept because it is the yardstick: it asks for the whole rule in one
    /// answer, which is what the bench compares the interview against. Not used by the app.
    func ruleInOneGo(from instruction: String, accounts: [String], mailboxes: [String]) async throws -> Rule {
        let prompt = ModelPrompt(
            role: "Conviertes instrucciones de un usuario en reglas de correo. Respondes solo con JSON.",
            fields: [.init(name: "instruccion", value: instruction),
                     .init(name: "cuentas_disponibles", value: accounts.joined(separator: ", ")),
                     .init(name: "buzones_disponibles", value: mailboxes.joined(separator: ", "))],
            task: Self.ruleTask)

        let answer = try await text(of: prompt)
        guard var draft = Self.draft(fromJSON: answer) else {
            throw ModelError.badAnswer("no devolvió un JSON con la forma pedida")
        }
        // Instructions name the mailbox and skip the account («mueve a Facturas lo de la gestoría»),
        // so the model has to guess one. With a single account there is nothing to guess; with
        // several, the user picks, because mail moved into the wrong account is the kind of mistake
        // nobody notices until it's needed.
        if draft.accion == "mover", accounts.count == 1 { draft.cuenta = accounts[0] }
        guard let rule = Self.rule(from: draft, accounts: accounts, mailboxes: mailboxes) else {
            if draft.accion == "mover", let mailbox = draft.buzon, mailboxes.contains(mailbox),
               !accounts.contains(draft.cuenta ?? "") {
                throw ModelError.missingAccount(mailbox: mailbox)
            }
            throw ModelError.badAnswer(Self.complaint(about: draft))
        }
        return rule
    }

    /// What came back, for the message and for the bench: «no es válida» on its own doesn't say
    /// which part to fix.
    nonisolated static func complaint(about draft: RuleDraft) -> String {
        "acción «\(draft.accion)», condiciones [\(draft.condiciones.map(\.tipo).joined(separator: ", "))], "
            + "cuenta «\(draft.cuenta ?? "-")», buzón «\(draft.buzon ?? "-")»"
    }

    /// Written against the bench (ARK-247), not from imagination. Two things it fixes, both of
    /// which a plain list of condition names got wrong on Apple's small model: «borra los boletines
    /// de más de 30 días» came back as *only* «older than 30 days» — a rule that deletes every old
    /// mail — and «marca como leídos los avisos de X» came back as «isRead: true», with the sender
    /// gone. Hence the line separating what the rule *picks* from what it *does*, and the worked
    /// examples: a small model copies a shape far better than it follows a description.
    nonisolated static let ruleTask = """
    Convierte «instruccion» en una regla de correo.

    Las condiciones dicen QUÉ correos elige la regla. La acción dice qué se hace con ellos. Nunca \
    pongas como condición el resultado que se busca.

    Condiciones (solo estas):
      senderContains → texto: el remitente contiene ese texto
      senderIs → texto: el remitente es exactamente esa dirección
      domainIs → texto: el remitente es de ese dominio
      subjectContains → texto: el asunto contiene ese texto
      olderThanDays → numero: recibido hace más de N días
      newerThanDays → numero: recibido hace menos de N días
      largerThanKB → numero: pesa más de N KB
      isRead → valor: está leído (true) o sin leer (false)
      accountIs → texto, mailboxIs → texto: limita la regla a esa cuenta o a ese buzón
      senderInImportant: el remitente está en la lista de importantes
      senderInNewsletters: el correo es un boletín

    Acciones: mover (lleva «cuenta» y «buzon», exactamente uno de los disponibles), archivar, \
    borrar, marcarLeido, bandera.

    Ejemplos:
    «archiva lo que pese más de 5 MB y tenga más de un año»
    {"nombre":"Correos grandes y viejos","coinciden":"todas","condiciones":[{"tipo":"largerThanKB","numero":5000},{"tipo":"olderThanDays","numero":365}],"accion":"archivar"}
    «ponle bandera a lo que venga de mi jefe, jefe@empresa.com»
    {"nombre":"Correos del jefe","coinciden":"todas","condiciones":[{"tipo":"senderIs","texto":"jefe@empresa.com"}],"accion":"bandera"}
    «borra los avisos de facebook que ya haya leído»
    {"nombre":"Avisos de Facebook leídos","coinciden":"todas","condiciones":[{"tipo":"domainIs","texto":"facebook.com"},{"tipo":"isRead","valor":true}],"accion":"borrar"}
    «marca como leídos los avisos de github»
    {"nombre":"Avisos de GitHub","coinciden":"todas","condiciones":[{"tipo":"domainIs","texto":"github.com"}],"accion":"marcarLeido"}
    Fíjate en el último: la acción ya es marcar como leído, así que «isRead» no va como condición. \
    Si la pones, la regla solo miraría los correos ya leídos y no haría nada.

    Responde solo con el JSON, en una línea. Si la instrucción no se puede expresar con lo de arriba, \
    responde {"nombre":"","coinciden":"todas","condiciones":[],"accion":""}.
    """

    // Validation is pure: no state, no main actor. It runs wherever the answer arrives.

    /// The JSON of the answer, tolerating code fences or a line of chatter around it.
    nonisolated static func draft(fromJSON answer: String) -> RuleDraft? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else { return nil }
        let json = String(answer[start...end])
        return try? JSONDecoder().decode(RuleDraft.self, from: Data(json.utf8))
    }

    /// Validates a draft against what the rules engine really accepts. An invented account or
    /// mailbox is rejected: a rule that moves mail somewhere unexpected is worse than no rule.
    nonisolated static func rule(from draft: RuleDraft, accounts: [String], mailboxes: [String]) -> Rule? {
        let conditions = draft.condiciones.compactMap { condition(from: $0, accounts: accounts, mailboxes: mailboxes) }
        guard conditions.count == draft.condiciones.count, !conditions.isEmpty else { return nil }
        guard let action = action(from: draft, accounts: accounts, mailboxes: mailboxes) else { return nil }
        let name = draft.nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return Rule(name: name, isEnabled: false, position: 0,
                    matchMode: draft.coinciden == "alguna" ? .any : .all,
                    conditions: conditions, action: action)
    }

    private nonisolated static func condition(from c: RuleDraft.Condition, accounts: [String], mailboxes: [String]) -> RuleCondition? {
        let text = (c.texto ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let number = c.numero ?? 0
        switch c.tipo {
        case "senderContains": return text.isEmpty ? nil : .senderContains(text)
        case "senderIs": return text.contains("@") ? .senderIs(text) : nil
        case "domainIs": return text.isEmpty ? nil : .domainIs(text)
        case "subjectContains": return text.isEmpty ? nil : .subjectContains(text)
        case "olderThanDays": return number > 0 ? .olderThanDays(number) : nil
        case "newerThanDays": return number > 0 ? .newerThanDays(number) : nil
        case "largerThanKB": return number > 0 ? .largerThanKB(number) : nil
        case "isRead": return c.valor.map { .isRead($0) }
        case "accountIs": return accounts.contains(text) ? .accountIs(text) : nil
        case "mailboxIs": return mailboxes.contains(text) ? .mailboxIs(text) : nil
        case "senderInImportant": return .senderInImportant
        case "senderInNewsletters": return .senderInNewsletters
        default: return nil
        }
    }

    private nonisolated static func action(from draft: RuleDraft, accounts: [String], mailboxes: [String]) -> RuleAction? {
        switch draft.accion {
        case "archivar": return .archive
        case "borrar": return .delete
        case "marcarLeido": return .markRead
        case "bandera": return .flag
        case "mover":
            guard let account = draft.cuenta, accounts.contains(account),
                  let mailbox = draft.buzon, mailboxes.contains(mailbox) else { return nil }
            return .move(account: account, mailbox: mailbox)
        default: return nil
        }
    }

    // MARK: - Plumbing

    private func fields(subject: String, sender: String, body: String) -> [ModelPrompt.Field] {
        [.init(name: "asunto", value: subject), .init(name: "remitente", value: sender), .init(name: "correo", value: body)]
    }

    private func text(of prompt: ModelPrompt) async throws -> String {
        guard model.availability.isReady else { throw ModelError.unavailable(model.availability) }
        let answer = try await model.answer(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ModelError.badAnswer("respuesta vacía") }
        return answer
    }
}
