import Foundation

/// Bridge to interact with Mail.app via AppleScript
final class MailBridge {

    static let shared = MailBridge()
    private init() {}

    // MARK: - Fetch all messages from a mailbox

    func fetchMessages(from mailbox: String = "INBOX", account: String? = nil, limit: Int = 500) async throws -> [MailMessage] {
        let accountFilter = account.map { "of account \"\($0)\"" } ?? ""

        let script = """
        tell application "Mail"
            set msgList to {}
            set theMessages to messages of mailbox "\(mailbox)" \(accountFilter)
            set msgCount to count of theMessages
            if msgCount > \(limit) then set msgCount to \(limit)
            repeat with i from 1 to msgCount
                set msg to item i of theMessages
                try
                    set msgSubject to subject of msg
                    set msgSender to sender of msg
                    set msgDate to date sent of msg
                    set msgDateReceived to date received of msg
                    set msgRead to read status of msg
                    set msgId to id of msg
                    set end of msgList to {msgSubject, msgSender, msgDate as string, msgDateReceived as string, msgRead, msgId}
                end try
            end repeat
            return msgList
        end tell
        """

        let results = try await runAppleScript(script)
        return parseMessages(results, mailbox: mailbox, account: account ?? "")
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

        let result = try await runAppleScript(script)
        return parseAccounts(result)
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

        let result = try await runAppleScript(script)
        return parseStringList(result)
    }

    // MARK: - Delete messages by IDs

    func deleteMessages(ids: [Int], mailbox: String, account: String? = nil) async throws -> Int {
        let accountFilter = account.map { "of account \"\($0)\"" } ?? ""
        let idList = ids.map(String.init).joined(separator: ", ")

        let script = """
        tell application "Mail"
            set deletedCount to 0
            set theMessages to messages of mailbox "\(mailbox)" \(accountFilter)
            repeat with msg in theMessages
                if (id of msg) is in {\(idList)} then
                    delete msg
                    set deletedCount to deletedCount + 1
                end if
            end repeat
            return deletedCount
        end tell
        """

        let result = try await runAppleScript(script)
        return Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Move messages to a mailbox

    func moveMessages(ids: [Int], fromMailbox: String, toMailbox: String, account: String? = nil) async throws -> Int {
        let accountFilter = account.map { "of account \"\($0)\"" } ?? ""

        let idList = ids.map(String.init).joined(separator: ", ")

        let script = """
        tell application "Mail"
            set movedCount to 0
            set targetMailbox to mailbox "\(toMailbox)" \(accountFilter)
            set theMessages to messages of mailbox "\(fromMailbox)" \(accountFilter)
            repeat with msg in theMessages
                if (id of msg) is in {\(idList)} then
                    move msg to targetMailbox
                    set movedCount to movedCount + 1
                end if
            end repeat
            return movedCount
        end tell
        """

        let result = try await runAppleScript(script)
        return Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Search messages by sender address

    func searchBySender(address: String, mailbox: String = "INBOX", account: String? = nil) async throws -> [MailMessage] {
        let accountFilter = account.map { "of account \"\($0)\"" } ?? ""

        let script = """
        tell application "Mail"
            set msgList to {}
            set theMessages to (messages of mailbox "\(mailbox)" \(accountFilter) whose sender contains "\(address)")
            repeat with msg in theMessages
                try
                    set msgSubject to subject of msg
                    set msgSender to sender of msg
                    set msgDate to date sent of msg
                    set msgDateReceived to date received of msg
                    set msgRead to read status of msg
                    set msgId to id of msg
                    set end of msgList to {msgSubject, msgSender, msgDate as string, msgDateReceived as string, msgRead, msgId}
                end try
            end repeat
            return msgList
        end tell
        """

        let results = try await runAppleScript(script)
        return parseMessages(results, mailbox: mailbox, account: account ?? "")
    }

    // MARK: - AppleScript execution

    private func runAppleScript(_ source: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)

                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: MailBridgeError.scriptError(message))
                    return
                }

                let output = result?.stringValue ?? ""
                continuation.resume(returning: output)
            }
        }
    }

    // MARK: - Parsing

    private func parseMessages(_ raw: String, mailbox: String, account: String) -> [MailMessage] {
        // AppleScript returns nested list as string; parse it
        var messages: [MailMessage] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .full
        dateFormatter.locale = Locale.current

        // Split by record boundaries
        let cleaned = raw
            .replacingOccurrences(of: "{{", with: "{")
            .replacingOccurrences(of: "}}", with: "}")

        let records = cleaned.components(separatedBy: "}, {")

        for record in records {
            let trimmed = record
                .replacingOccurrences(of: "{", with: "")
                .replacingOccurrences(of: "}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let parts = splitAppleScriptRecord(trimmed)
            guard parts.count >= 6 else { continue }

            let subject = parts[0].trimmingCharacters(in: .init(charactersIn: "\" "))
            let senderRaw = parts[1].trimmingCharacters(in: .init(charactersIn: "\" "))
            let dateSentStr = parts[2].trimmingCharacters(in: .init(charactersIn: "\" "))
            let dateRecStr = parts[3].trimmingCharacters(in: .init(charactersIn: "\" "))
            let isReadStr = parts[4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let idStr = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)

            let senderAddress = extractEmail(from: senderRaw)
            let senderName = extractName(from: senderRaw)

            let msg = MailMessage(
                id: "\(account)-\(mailbox)-\(idStr)",
                subject: subject,
                sender: senderName,
                senderAddress: senderAddress,
                dateSent: dateFormatter.date(from: dateSentStr) ?? Date(),
                dateReceived: dateFormatter.date(from: dateRecStr) ?? Date(),
                isRead: isReadStr == "true",
                mailbox: mailbox,
                account: account,
                messageId: Int(idStr) ?? 0
            )
            messages.append(msg)
        }

        return messages
    }

    private func splitAppleScriptRecord(_ record: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false

        for char in record {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == "," && !inQuotes {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            parts.append(current.trimmingCharacters(in: .whitespaces))
        }
        return parts
    }

    private func extractEmail(from sender: String) -> String {
        if let start = sender.lastIndex(of: "<"),
           let end = sender.lastIndex(of: ">") {
            return String(sender[sender.index(after: start)..<end]).lowercased()
        }
        // Already just an email
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

    private func parseAccounts(_ raw: String) -> [(name: String, mailboxes: [String])] {
        // Simplified parsing
        return []
    }

    private func parseStringList(_ raw: String) -> [String] {
        return raw
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .init(charactersIn: "\" \n\r\t")) }
            .filter { !$0.isEmpty }
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
