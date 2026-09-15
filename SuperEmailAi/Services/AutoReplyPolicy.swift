import Foundation

/// Who the out-of-office reply may answer (ARK-200, ARK-213): important senders always, and with
/// «A todos» also anyone you have written to before. Never a first-time sender: an unknown From
/// may be forged, and answering it confirms your address to spammers. Until the Sent history is
/// indexed an old contact may not be recognised yet; then it doesn't answer, the safe side.
enum AutoReplyPolicy {
    static func mayAnswer(scope: MailManager.AutoReplyScope, isImportant: Bool, hasWrittenTo: Bool) -> Bool {
        isImportant || (scope == .all && hasWrittenTo)
    }
}
