import Foundation

/// Plain Spanish for a rule: the name the user reads, and the wording of the questions the model is
/// asked. Built in Swift on purpose — asking the model for a name would be one more call, one more
/// wait, and one more thing that can come back in English.
enum RuleWording {
    /// A whole clause, for a question: «¿la regla se limita a los correos que **son boletines**?»
    static func describe(_ condition: RuleCondition) -> String {
        switch condition {
        case .senderContains(let text): "el remitente contiene «\(text)»"
        case .senderIs(let text): "el remitente es \(text)"
        case .domainIs(let domain): "vienen de \(domain)"
        case .subjectContains(let text): "el asunto contiene «\(text)»"
        case .olderThanDays(let days): "tienen más de \(days) días"
        case .newerThanDays(let days): "tienen menos de \(days) días"
        case .isRead(let read): read ? "están leídos" : "están sin leer"
        case .accountIs(let account): "están en la cuenta \(account)"
        case .mailboxIs(let mailbox): "están en \(mailbox)"
        case .largerThanKB(let kb): "pesan más de \(size(kb))"
        case .senderInImportant: "el remitente está en tu lista de importantes"
        case .senderInNewsletters: "son boletines"
        }
    }

    /// The same thing in the few words a name can hold.
    static func short(_ condition: RuleCondition) -> String {
        switch condition {
        case .senderContains(let text): "de «\(text)»"
        case .senderIs(let address): "de \(address)"
        case .domainIs(let domain): "de \(domain)"
        case .subjectContains(let text): "con «\(text)» en el asunto"
        case .olderThanDays(let days): "de más de \(days) días"
        case .newerThanDays(let days): "de menos de \(days) días"
        case .isRead(let read): read ? "leídos" : "sin leer"
        case .accountIs(let account): "de \(account)"
        case .mailboxIs(let mailbox): "de \(mailbox)"
        case .largerThanKB(let kb): "de más de \(size(kb))"
        case .senderInImportant: "de remitentes importantes"
        case .senderInNewsletters: "boletines"
        }
    }

    static func verb(_ action: RuleAction) -> String {
        switch action {
        case .move(_, let mailbox): "Mover a \(mailbox)"
        case .archive: "Archivar"
        case .delete: "Borrar"
        case .markRead: "Marcar como leído"
        case .flag: "Poner bandera a"
        }
    }

    /// A name someone can recognise in a list: «Borrar boletines, de más de 30 días».
    static func name(action: RuleAction, conditions: [RuleCondition]) -> String {
        let parts = conditions.map(short)
        let name = ([verb(action)] + [parts.joined(separator: ", ")])
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard name.count > 60 else { return name }
        return String(name.prefix(59)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func size(_ kb: Int) -> String {
        kb >= 1000 ? "\(kb / 1000) MB" : "\(kb) KB"
    }
}
