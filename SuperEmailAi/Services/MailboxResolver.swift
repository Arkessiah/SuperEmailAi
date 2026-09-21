import Foundation

/// Finds an account's Archive / Trash / Sent among its real mailbox names (they vary by
/// provider and language). Returns nil when none is found: the caller reports it.
enum MailboxResolver {
    static let archiveNames = ["Archive", "Archivo", "Archivado", "Archived", "All Mail",
                               "[Gmail]/All Mail", "[Gmail]/Todos", "Todos"]
    static let trashNames = ["Trash", "Papelera", "Deleted Messages", "Deleted Items",
                             "Elementos eliminados", "[Gmail]/Trash", "[Gmail]/Papelera", "Bin"]
    static let sentNames = ["Sent Messages", "Sent", "Enviados", "Mensajes enviados", "Sent Items",
                            "Elementos enviados", "Sent Mail", "[Gmail]/Sent Mail", "[Gmail]/Enviados",
                            "Correo enviado", "Enviado"]

    static func archive(in mailboxes: [String]) -> String? { first(of: archiveNames, in: mailboxes) }
    static func trash(in mailboxes: [String]) -> String? { first(of: trashNames, in: mailboxes) }
    static func sent(in mailboxes: [String]) -> String? { first(of: sentNames, in: mailboxes) }

    /// Archive mailbox per account; accounts without one are reported in `missing` (sorted).
    static func archiveTargets(for accounts: Set<String>,
                               mailboxesOf: (String) -> [String]) -> (targets: [String: String], missing: [String]) {
        var targets: [String: String] = [:]
        var missing: [String] = []
        for account in accounts.sorted() {
            if let box = archive(in: mailboxesOf(account)) { targets[account] = box } else { missing.append(account) }
        }
        return (targets, missing)
    }

    private static func first(of candidates: [String], in mailboxes: [String]) -> String? {
        for name in candidates {
            if let hit = mailboxes.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return hit }
        }
        return nil
    }
}

/// Safe AppleScript string literals: drops control characters, escapes `\` and `"`.
enum AppleScriptText {
    static func quoted(_ s: String) -> String {
        // Only true control characters: `controlCharacters` also drops format ones such as the
        // zero-width joiner, which would break mailbox names with composed emoji.
        let kept = s.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let text = String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(text)\""
    }

    /// `mailbox "Name" of account "Account"`, both escaped; without account when nil.
    static func mailbox(_ name: String, account: String?) -> String {
        "mailbox \(quoted(name))" + (account.map { " of account \(quoted($0))" } ?? "")
    }
}
