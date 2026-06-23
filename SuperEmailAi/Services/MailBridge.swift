import Foundation

/// Bridge to interact with Mail.app via AppleScript.
///
/// Messages are read with a per-message `try` so one bad message (missing
/// property) doesn't drop the whole mailbox. Results are read structurally from
/// the returned `NSAppleEventDescriptor`. Each message carries its real owning
/// account (7th field) so delete/move can target the right mailbox.
final class MailBridge {

    static let shared = MailBridge()
    private init() {}

    // AppleScript list descriptor type ('list').
    private static let listType: DescType = 0x6C697374

    // MARK: - Fetch all messages from a mailbox

    func fetchMessages(from mailbox: String = "INBOX", account: String? = nil, limit: Int = 500) async throws -> [MailMessage] {
        let script: String
        if let account = account {
            script = """
            tell application "Mail"
                set msgList to {}
                try
                    set theMessages to messages of mailbox "\(mailbox)" of account "\(account)"
                on error
                    set theMessages to {}
                end try
                set msgCount to count of theMessages
                if msgCount > \(limit) then set msgCount to \(limit)
                repeat with i from 1 to msgCount
                    set msg to item i of theMessages
                    try
                        set end of msgList to {subject of msg, sender of msg, date sent of msg, date received of msg, read status of msg, id of msg, "\(account)"}
                    end try
                end repeat
                return msgList
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                set msgList to {}
                set collected to 0
                repeat with acc in accounts
                    set accName to name of acc
                    try
                        set theMessages to messages of mailbox "\(mailbox)" of acc
                    on error
                        set theMessages to {}
                    end try
                    set msgCount to count of theMessages
                    repeat with i from 1 to msgCount
                        if collected > \(limit - 1) then exit repeat
                        set msg to item i of theMessages
                        try
                            set end of msgList to {subject of msg, sender of msg, date sent of msg, date received of msg, read status of msg, id of msg, accName}
                            set collected to collected + 1
                        end try
                    end repeat
                    if collected > \(limit - 1) then exit repeat
                end repeat
                return msgList
            end tell
            """
        }

        let descriptor = try await runAppleScript(script)
        return parseMessages(from: descriptor, mailbox: mailbox)
    }

    // MARK: - Get all accounts and mailboxes

    func fetchAccounts() async throws -> [(name: String, mailboxes: [String])] {
        let script = """
        tell application "Mail"
            set accountList to {}
            repeat with acc in accounts
                set accName to name of acc
                set mbNames to {}
                repeat with mb in mailboxes of acc
                    set end of mbNames to name of mb
                end repeat
                set end of accountList to {accName, mbNames}
            end repeat
            return accountList
        end tell
        """

        let descriptor = try await runAppleScript(script)
        return parseAccounts(from: descriptor)
    }

    // MARK: - Get all mailbox names for folder picker

    func fetchMailboxNames() async throws -> [String] {
        let script = """
        tell application "Mail"
            set mbNames to {}
            repeat with acc in accounts
                repeat with mb in mailboxes of acc
                    set end of mbNames to name of mb
                end repeat
            end repeat
            return mbNames
        end tell
        """

        let descriptor = try await runAppleScript(script)
        return parseStringList(from: descriptor)
    }

    // MARK: - Delete messages by IDs

    func deleteMessages(ids: [Int], mailbox: String, account: String? = nil) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let accountFilter = account.map { "of account \"\($0)\"" } ?? ""
        let idList = ids.map(String.init).joined(separator: ", ")

        // Resolve each target by id with a `whose` filter (evaluated inside Mail)
        // instead of marshalling every message in the mailbox across Apple Events.
        let script = """
        tell application "Mail"
            set deletedCount to 0
            set theMailbox to mailbox "\(mailbox)" \(accountFilter)
            repeat with theId in {\(idList)}
                try
                    delete (first message of theMailbox whose id is (theId as integer))
                    set deletedCount to deletedCount + 1
                end try
            end repeat
            return deletedCount
        end tell
        """

        let descriptor = try await runAppleScript(script)
        return Int(descriptor.int32Value)
    }

    // MARK: - Move messages to a mailbox

    func moveMessages(ids: [Int], fromMailbox: String, toMailbox: String, account: String? = nil) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let accountFilter = account.map { "of account \"\($0)\"" } ?? ""
        let idList = ids.map(String.init).joined(separator: ", ")

        let script = """
        tell application "Mail"
            set movedCount to 0
            set targetMailbox to mailbox "\(toMailbox)" \(accountFilter)
            set theMailbox to mailbox "\(fromMailbox)" \(accountFilter)
            repeat with theId in {\(idList)}
                try
                    move (first message of theMailbox whose id is (theId as integer)) to targetMailbox
                    set movedCount to movedCount + 1
                end try
            end repeat
            return movedCount
        end tell
        """

        let descriptor = try await runAppleScript(script)
        return Int(descriptor.int32Value)
    }

    // MARK: - Search messages by sender address

    func searchBySender(address: String, mailbox: String = "INBOX", account: String? = nil) async throws -> [MailMessage] {
        let script: String
        if let account = account {
            script = """
            tell application "Mail"
                set msgList to {}
                try
                    set theMessages to (messages of mailbox "\(mailbox)" of account "\(account)" whose sender contains "\(address)")
                on error
                    set theMessages to {}
                end try
                repeat with msg in theMessages
                    try
                        set end of msgList to {subject of msg, sender of msg, date sent of msg, date received of msg, read status of msg, id of msg, "\(account)"}
                    end try
                end repeat
                return msgList
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                set msgList to {}
                repeat with acc in accounts
                    set accName to name of acc
                    try
                        set theMessages to (messages of mailbox "\(mailbox)" of acc whose sender contains "\(address)")
                    on error
                        set theMessages to {}
                    end try
                    repeat with msg in theMessages
                        try
                            set end of msgList to {subject of msg, sender of msg, date sent of msg, date received of msg, read status of msg, id of msg, accName}
                        end try
                    end repeat
                end repeat
                return msgList
            end tell
            """
        }

        let descriptor = try await runAppleScript(script)
        return parseMessages(from: descriptor, mailbox: mailbox)
    }

    // MARK: - Fetch a single message's body

    func fetchMessageContent(id: Int, mailbox: String, account: String? = nil) async throws -> String {
        let accountFilter = account.map { "of account \"\($0)\"" } ?? ""
        let script = """
        tell application "Mail"
            set theMessage to (first message of mailbox "\(mailbox)" \(accountFilter) whose id is \(id))
            return content of theMessage
        end tell
        """

        let descriptor = try await runAppleScript(script)
        return descriptor.stringValue ?? ""
    }

    // MARK: - AppleScript execution

    /// Runs the script and returns the raw `NSAppleEventDescriptor` result.
    private func runAppleScript(_ source: String) async throws -> NSAppleEventDescriptor {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: MailBridgeError.scriptError("No se pudo compilar el AppleScript"))
                    return
                }
                let result = script.executeAndReturnError(&error)

                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: MailBridgeError.scriptError(message))
                    return
                }

                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Structured parsing (NSAppleEventDescriptor)

    /// Returns the elements of a list descriptor, or `[descriptor]` for a scalar,
    /// or `[]` for an empty list.
    private func listItems(_ descriptor: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
        guard let descriptor = descriptor else { return [] }
        if descriptor.descriptorType == Self.listType {
            let n = descriptor.numberOfItems
            guard n > 0 else { return [] }
            return (1...n).compactMap { descriptor.atIndex($0) }
        }
        return [descriptor]
    }

    /// Parses a list of message records: `{subject, sender, dateSent, dateReceived, read, id, accountName}`.
    private func parseMessages(from descriptor: NSAppleEventDescriptor, mailbox: String) -> [MailMessage] {
        var messages: [MailMessage] = []

        for record in listItems(descriptor) {
            guard record.numberOfItems >= 6 else { continue }

            let subject = record.atIndex(1)?.stringValue ?? "(sin asunto)"
            let senderRaw = record.atIndex(2)?.stringValue ?? ""
            let dateSent = record.atIndex(3)?.dateValue ?? Date()
            let dateReceived = record.atIndex(4)?.dateValue ?? Date()
            let isRead = record.atIndex(5)?.booleanValue ?? false
            let messageId = Int(record.atIndex(6)?.int32Value ?? 0)
            let account = record.numberOfItems >= 7 ? (record.atIndex(7)?.stringValue ?? "") : ""

            let senderAddress = extractEmail(from: senderRaw)
            let senderName = extractName(from: senderRaw)

            messages.append(MailMessage(
                id: "\(account)-\(mailbox)-\(messageId)",
                subject: subject,
                sender: senderName,
                senderAddress: senderAddress,
                dateSent: dateSent,
                dateReceived: dateReceived,
                isRead: isRead,
                mailbox: mailbox,
                account: account,
                messageId: messageId
            ))
        }

        return messages
    }

    /// Parses a list of account records: `{accountName, {mailboxName, ...}}`.
    private func parseAccounts(from descriptor: NSAppleEventDescriptor) -> [(name: String, mailboxes: [String])] {
        var accounts: [(name: String, mailboxes: [String])] = []

        for entry in listItems(descriptor) {
            guard entry.numberOfItems >= 2 else { continue }
            let name = entry.atIndex(1)?.stringValue ?? ""
            guard !name.isEmpty else { continue }

            let mailboxes = listItems(entry.atIndex(2))
                .compactMap { $0.stringValue }
                .filter { !$0.isEmpty }

            accounts.append((name: name, mailboxes: mailboxes))
        }

        return accounts
    }

    /// Parses a flat AppleScript list of strings.
    private func parseStringList(from descriptor: NSAppleEventDescriptor) -> [String] {
        return listItems(descriptor)
            .compactMap { $0.stringValue }
            .filter { !$0.isEmpty }
    }

    // MARK: - Sender parsing helpers

    private func extractEmail(from sender: String) -> String {
        if let start = sender.lastIndex(of: "<"),
           let end = sender.lastIndex(of: ">"),
           start < end {
            return String(sender[sender.index(after: start)..<end]).lowercased()
        }
        if sender.contains("@") {
            return sender.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sender.lowercased()
    }

    private func extractName(from sender: String) -> String {
        if let start = sender.lastIndex(of: "<") {
            let name = String(sender[sender.startIndex..<start])
                .trimmingCharacters(in: .init(charactersIn: "\" "))
            return name.isEmpty ? extractEmail(from: sender) : name
        }
        return sender
    }
}

// MARK: - Errors

enum MailBridgeError: LocalizedError {
    case scriptError(String)
    case noResults

    var errorDescription: String? {
        switch self {
        case .scriptError(let msg): return "Mail Script Error: \(msg)"
        case .noResults: return "No results returned from Mail.app"
        }
    }
}
