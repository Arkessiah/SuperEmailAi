import Foundation

/// What can be read out of an instruction without asking a model: addresses, domains, numbers with
/// their unit, and the words that point at a condition.
///
/// This exists because of what was measured on 2026-09-28 (`DOC/ES/medidas-ia-en-el-aparato.md`):
/// asked to compose a whole rule, Apple's on-device model dropped «is a newsletter» from «borra los
/// boletines de más de 30 días» in two runs out of three, leaving a rule that deletes every old
/// mail. Conditions read here come from the user's own sentence, so an answer can drop one, but
/// nothing can invent one.
struct RuleSketch: Equatable {
    /// A condition the sentence points at.
    struct Candidate: Equatable {
        var condition: RuleCondition
        /// The words it came from, to ask about it in plain Spanish.
        var evidence: String
        /// True when the sentence leaves no room for judgement: an address, a number with its unit.
        /// The uncertain ones are the only thing the model gets asked about.
        var certain: Bool
    }

    var candidates: [Candidate] = []
    /// Real mailbox names the sentence names, for a «mover» action.
    var mailboxes: [String] = []
    /// Real account names the sentence names.
    var accounts: [String] = []

    var certain: [RuleCondition] { candidates.filter(\.certain).map(\.condition) }
    var uncertain: [Candidate] { candidates.filter { !$0.certain } }

    // MARK: - Reading

    static func read(_ instruction: String, accounts: [String] = [], mailboxes: [String] = []) -> RuleSketch {
        var sketch = RuleSketch()
        let text = withoutTheAction(plain(instruction))
        let tokens = words(of: instruction)

        // Who the mail is from comes first, then what it says, then when and how big: that order is
        // how the rule's name reads («Borrar boletines, de más de 30 días»).
        if let sender = senderCondition(in: tokens) { sketch.candidates.append(sender) }
        if newsletterCues.contains(where: text.contains) {
            sketch.candidates.append(.init(condition: .senderInNewsletters, evidence: "boletines", certain: true))
        }
        // «importantes» can mean the list or just emphasis, so this one gets asked.
        if importantCues.contains(where: text.contains) {
            sketch.candidates.append(.init(condition: .senderInImportant,
                                           evidence: "remitentes de tu lista de importantes", certain: false))
        }
        if let subject = subjectCondition(in: instruction) { sketch.candidates.append(subject) }
        if let age = ageCondition(in: text) { sketch.candidates.append(age) }
        if let size = sizeCondition(in: text) { sketch.candidates.append(size) }
        if let read = readCondition(in: text) { sketch.candidates.append(read) }

        // Names are matched against what the user really has, so nothing made up gets this far.
        sketch.mailboxes = mailboxes.filter { text.contains(plain($0)) }
        sketch.accounts = accounts.filter { text.contains(plain($0)) }
        return sketch
    }

    /// «marca como leídos los avisos de X» says «leídos» about what to *do*, not about which mail
    /// to pick. Reading it as a condition gives a rule that only touches mail already read — that
    /// is, one that does nothing. It is the same mistake the model made when it composed rules on
    /// its own, and here it costs one line to be rid of. «borra los leídos» still works: only the
    /// «como leído» form is dropped.
    private static func withoutTheAction(_ text: String) -> String {
        var clean = text
        for phrase in ["como leidos", "como leido", "as read"] {
            clean = clean.replacingOccurrences(of: phrase, with: " ")
        }
        return clean
    }

    // MARK: - Sender

    private static func senderCondition(in tokens: [String]) -> Candidate? {
        for token in tokens where token.contains("@") && !token.hasPrefix("@") {
            let address = token.lowercased()
            if address.contains("."), address.count > 5 {
                return .init(condition: .senderIs(address), evidence: address, certain: true)
            }
        }
        for token in tokens where token.hasPrefix("@") && token.count > 2 {
            let domain = String(token.dropFirst()).lowercased()
            return .init(condition: .domainIs(domain), evidence: domain, certain: true)
        }
        for token in tokens {
            let candidate = token.lowercased()
            guard tlds.contains(where: { candidate.hasSuffix($0) }), candidate.count > 4,
                  Int(candidate.prefix(1)) == nil else { continue }
            return .init(condition: .domainIs(candidate), evidence: candidate, certain: true)
        }
        return nil
    }

    private static let tlds = [".com", ".es", ".io", ".org", ".net", ".xyz", ".co", ".tech",
                               ".dev", ".app", ".info", ".eu", ".biz", ".cat", ".gal"]

    // MARK: - Age

    /// «de más de 30 días» and «de la última semana» are opposite conditions built from the same
    /// number and unit, so the direction is read separately from the amount.
    private static func ageCondition(in text: String) -> Candidate? {
        guard let (days, _) = amount(in: text, units: ageUnits) else { return nil }
        let newer = newerCues.contains { text.contains($0) }
        return .init(condition: newer ? .newerThanDays(days) : .olderThanDays(days),
                     evidence: newer ? "de menos de \(days) días" : "de más de \(days) días",
                     certain: true)
    }

    // Whole words, not prefixes: «mesa» starts with «mes» and would become thirty days.
    private static let ageUnits = ["dia": 1, "dias": 1, "day": 1, "days": 1,
                                   "semana": 7, "semanas": 7, "week": 7, "weeks": 7,
                                   "mes": 30, "meses": 30, "month": 30, "months": 30,
                                   "ano": 365, "anos": 365, "year": 365, "years": 365]
    private static let newerCues = ["menos de", "ultim", "reciente", "de hoy", "de ayer", "last", "newer"]

    // MARK: - Size

    private static func sizeCondition(in text: String) -> Candidate? {
        guard let (kb, _) = amount(in: text, units: sizeUnits) else { return nil }
        return .init(condition: .largerThanKB(kb), evidence: sizeEvidence(kb), certain: true)
    }

    private static let sizeUnits = ["kb": 1, "kbs": 1, "kilobyte": 1, "kilobytes": 1,
                                    "mb": 1000, "mbs": 1000, "mega": 1000, "megas": 1000,
                                    "megabyte": 1000, "megabytes": 1000,
                                    "gb": 1_000_000, "giga": 1_000_000, "gigas": 1_000_000]

    private static func sizeEvidence(_ kb: Int) -> String {
        kb >= 1000 ? "que pesen más de \(kb / 1000) MB" : "que pesen más de \(kb) KB"
    }

    /// Finds «<número> <unidad>» and turns it into the unit's base amount. Written numbers count,
    /// because «de más de un mes» is how people say it.
    private static func amount(in text: String, units: [String: Int]) -> (Int, String)? {
        let words = words(of: text)
        for (index, word) in words.enumerated() {
            // «5mb» is written glued as often as «5 mb».
            if let glued = glued(word, units: units) { return glued }
            guard let factor = units[word], index > 0 else { continue }
            if let number = Int(words[index - 1]) { return (number * factor, word) }
            if let number = spelled[words[index - 1]] { return (number * factor, word) }
            if ones.contains(words[index - 1]) { return (factor, word) }
        }
        return nil
    }

    private static func glued(_ word: String, units: [String: Int]) -> (Int, String)? {
        let digits = word.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits),
              let factor = units[String(word.dropFirst(digits.count))] else { return nil }
        return (number * factor, word)
    }

    private static let spelled = ["dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6,
                                  "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "doce": 12]
    /// Words that stand for «one of those» — «de más de un mes», «de la última semana».
    private static let ones = ["un", "una", "el", "la", "del", "de", "a", "one",
                               "ultima", "ultimo", "esta", "este", "pasada", "pasado", "last"]

    /// Splits a sentence into words, keeping the dots *inside* a token — a domain is one word —
    /// and dropping the ones that merely end a sentence.
    private static func words(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: " \t\n\r,;:\"'«»“”()¿?¡!"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Read state, categories, subject

    private static func readCondition(in text: String) -> Candidate? {
        if unreadCues.contains(where: text.contains) {
            return .init(condition: .isRead(false), evidence: "sin leer", certain: true)
        }
        if readCues.contains(where: text.contains) {
            return .init(condition: .isRead(true), evidence: "ya leídos", certain: true)
        }
        return nil
    }

    // Checked before the read ones: «no leidos» contains «leidos».
    private static let unreadCues = ["no leido", "sin leer", "no abierto", "sin abrir", "unread", "not read"]
    private static let readCues = ["leido", "abierto", " read"]
    private static let newsletterCues = ["boletin", "newsletter", "publicidad", "promocion",
                                         "suscripcion", "novedades"]
    private static let importantCues = ["important"]

    /// Only what the sentence quotes or names after «asunto», and it still gets asked about: a word
    /// in quotes could be a subject, a folder or just emphasis.
    private static func subjectCondition(in instruction: String) -> Candidate? {
        for (open, close) in [("«", "»"), ("\"", "\""), ("“", "”")] {
            guard let start = instruction.range(of: open),
                  let end = instruction.range(of: close, range: start.upperBound..<instruction.endIndex)
            else { continue }
            let quoted = String(instruction[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !quoted.isEmpty, !quoted.contains("@") {
                return .init(condition: .subjectContains(quoted),
                             evidence: "que el asunto contenga «\(quoted)»", certain: false)
            }
        }
        let text = plain(instruction)
        for cue in ["asunto ", "que diga ", "que digan ", "que hablen de ", "que contenga ", "que contengan "] {
            guard let range = text.range(of: cue) else { continue }
            let rest = text[range.upperBound...].components(separatedBy: CharacterSet(charactersIn: ",.;"))[0]
            let word = rest.trimmingCharacters(in: .whitespaces)
            if word.count > 2 {
                return .init(condition: .subjectContains(word),
                             evidence: "que el asunto contenga «\(word)»", certain: false)
            }
        }
        return nil
    }

    static func plain(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
    }
}
