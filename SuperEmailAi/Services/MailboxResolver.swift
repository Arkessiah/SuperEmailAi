import Foundation

/// Finds an account's Archive / Trash among its real mailbox names (they vary by
/// provider and language). Returns nil when none is found: the caller reports it.
enum MailboxResolver {
    static let archiveNames = ["Archive", "Archivo", "Archivado", "Archived", "All Mail",
                               "[Gmail]/All Mail", "[Gmail]/Todos", "Todos"]
    static let trashNames = ["Trash", "Papelera", "Deleted Messages", "Deleted Items",
                             "Elementos eliminados", "[Gmail]/Trash", "[Gmail]/Papelera", "Bin"]

    static func archive(in mailboxes: [String]) -> String? { first(of: archiveNames, in: mailboxes) }
    static func trash(in mailboxes: [String]) -> String? { first(of: trashNames, in: mailboxes) }

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
        let kept = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(text)\""
    }
}
