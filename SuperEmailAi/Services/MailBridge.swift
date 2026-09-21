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
            // Only the newest `limit` messages (not every reference in the mailbox), and Mail
            // errors throw: the alerts monitor must never take a failed read for an empty INBOX.
            script = Self.rangeScript(mailbox: mailbox, account: account, offset: 0, limit: limit, recipients: false)
        } else {
            script = """
            tell application "Mail"
                set msgList to {}
                set collected to 0
                repeat with acc in accounts
                    set accName to name of acc
                    try
                        set theMessages to messages of mailbox \(AppleScriptText.quoted(mailbox)) of acc
                    on error
                        set theMessages to {}
                    end try
                    set msgCount to count of theMessages
                    repeat with i from 1 to msgCount
                        if collected > \(limit - 1) then exit repeat
                        set msg to item i of theMessages
                        try
                            \(Self.recordScript(account: "accName"))
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

    /// Fetches a range of messages (for pagination): items `offset+1 ... offset+limit`
    /// of one account's mailbox. Returns `[]` past the end; throws when Mail fails, so a
    /// backfill never takes a failure for the end of the mailbox (ARK-217).
    func fetchMessagesRange(mailbox: String, account: String, offset: Int, limit: Int) async throws -> [MailMessage] {
        let script = Self.rangeScript(mailbox: mailbox, account: account, offset: offset, limit: limit, recipients: false)
        return parseMessages(from: try await runAppleScript(script), mailbox: mailbox)
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

    // MARK: - Bulk cleanup by predicate (acts on the whole mailbox in Mail)

    /// Counts messages in a mailbox matching an AppleScript `whose` predicate
    /// (e.g. `read status is true and date received < ((current date) - (30 * days))`).
    /// Empty predicate counts everything.
    func bulkCount(mailbox: String, account: String, predicate: String) async throws -> Int {
        let whoseClause = predicate.isEmpty ? "" : "whose \(predicate)"
        let script = """
        tell application "Mail"
            try
                return count of (messages of \(AppleScriptText.mailbox(mailbox, account: account)) \(whoseClause))
            on error
                return -1
            end try
        end tell
        """
        let descriptor = try await runAppleScript(script)
        return Int(descriptor.int32Value)
    }

    /// Deletes (moves to Trash) all messages matching the predicate. Returns how
    /// many were deleted.
    func bulkDelete(mailbox: String, account: String, predicate: String) async throws -> Int {
        let whoseClause = predicate.isEmpty ? "" : "whose \(predicate)"
        let script = """
        tell application "Mail"
            set theMatches to (messages of \(AppleScriptText.mailbox(mailbox, account: account)) \(whoseClause))
            set n to (count of theMatches)
            delete theMatches
            return n
        end tell
        """
        let descriptor = try await runAppleScript(script)
        return Int(descriptor.int32Value)
    }

    // MARK: - Delete messages by IDs

    func deleteMessages(ids: [Int], mailbox: String, account: String? = nil) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let idList = ids.map(String.init).joined(separator: ", ")

        // Resolve each target by id with a `whose` filter (evaluated inside Mail)
        // instead of marshalling every message in the mailbox across Apple Events.
        let script = """
        tell application "Mail"
            set deletedCount to 0
            set theMailbox to \(AppleScriptText.mailbox(mailbox, account: account))
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

    // MARK: - Set read status by IDs

    func setReadStatus(ids: [Int], read: Bool, mailbox: String, account: String? = nil) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let idList = ids.map(String.init).joined(separator: ", ")

        let script = """
        tell application "Mail"
            set changed to 0
            set theMailbox to \(AppleScriptText.mailbox(mailbox, account: account))
            repeat with theId in {\(idList)}
                try
                    set read status of (first message of theMailbox whose id is (theId as integer)) to \(read)
                    set changed to changed + 1
                end try
            end repeat
            return changed
        end tell
        """

        let descriptor = try await runAppleScript(script)
        return Int(descriptor.int32Value)
    }

    // MARK: - Move messages to a mailbox

    func moveMessages(ids: [Int], fromMailbox: String, toMailbox: String, account: String? = nil) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let idList = ids.map(String.init).joined(separator: ", ")

        let script = """
        tell application "Mail"
            set movedCount to 0
            set targetMailbox to \(AppleScriptText.mailbox(toMailbox, account: account))
            set theMailbox to \(AppleScriptText.mailbox(fromMailbox, account: account))
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
        let script = Self.senderSearchScript(address: address, mailbox: mailbox, account: account)
        return parseMessages(from: try await runAppleScript(script), mailbox: mailbox)
    }

    /// Messages whose sender contains `address`, in one account or in all of them. The address
    /// can come from a received mail, so it is always escaped (ARK-218).
    static func senderSearchScript(address: String, mailbox: String, account: String?) -> String {
        let filter = "whose sender contains \(AppleScriptText.quoted(address))"
        if let account {
            return """
            tell application "Mail"
                set msgList to {}
                try
                    set theMessages to (messages of \(AppleScriptText.mailbox(mailbox, account: account)) \(filter))
                on error
                    set theMessages to {}
                end try
                repeat with msg in theMessages
                    try
                        \(recordScript(account: AppleScriptText.quoted(account)))
                    end try
                end repeat
                return msgList
            end tell
            """
        }
        return """
        tell application "Mail"
            set msgList to {}
            repeat with acc in accounts
                set accName to name of acc
                try
                    set theMessages to (messages of mailbox \(AppleScriptText.quoted(mailbox)) of acc \(filter))
                on error
                    set theMessages to {}
                end try
                repeat with msg in theMessages
                    try
                        \(recordScript(account: "accName"))
                    end try
                end repeat
            end repeat
            return msgList
        end tell
        """
    }

    // MARK: - Send a message (used by auto-reply)

    func sendMail(to recipient: String, subject: String, body: String, fromAccount: String) async throws {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\" & return & \"")
        }
        let script = """
        tell application "Mail"
            set acc to account "\(esc(fromAccount))"
            set theMessage to make new outgoing message with properties {subject:"\(esc(subject))", content:"\(esc(body))", visible:false}
            tell theMessage
                make new to recipient at end of to recipients with properties {address:"\(esc(recipient))"}
            end tell
            try
                set sender of theMessage to (item 1 of (email addresses of acc))
            end try
            send theMessage
        end tell
        """
        _ = try await runAppleScript(script)
    }

    // MARK: - Fetch a single message's body (plain text + raw source for HTML)

    func fetchMessageRaw(id: Int, mailbox: String, account: String? = nil) async throws -> (content: String, source: String, recipients: [String]) {
        let script = """
        tell application "Mail"
            set theMessage to (first message of \(AppleScriptText.mailbox(mailbox, account: account)) whose id is \(id))
            set recipList to {}
            try
                set recipList to (address of to recipients of theMessage)
            end try
            return {content of theMessage, source of theMessage, recipList}
        end tell
        """

        let descriptor = try await runAppleScript(script)
        let items = listItems(descriptor)
        let content = items.count > 0 ? (items[0].stringValue ?? "") : ""
        let source = items.count > 1 ? (items[1].stringValue ?? "") : ""
        let recipients = items.count > 2 ? listItems(items[2]).compactMap { $0.stringValue }.filter { !$0.isEmpty } : []
        return (content: content, source: source, recipients: recipients)
    }

    // MARK: - Fetch a single message's headers (cheaper than the full source)

    func fetchHeaders(id: Int, mailbox: String, account: String? = nil) async throws -> String {
        let script = """
        tell application "Mail"
            return all headers of (first message of \(AppleScriptText.mailbox(mailbox, account: account)) whose id is \(id))
        end tell
        """
        return try await runAppleScript(script).stringValue ?? ""
    }

    // MARK: - AppleScript execution

    /// Serial queue: Mail Apple events must not run concurrently, or overlapping
    /// scripts (refresh + backfill + prefetch) fail intermittently and return empty.
    private static let scriptQueue = DispatchQueue(label: "com.superemailai.applescript", qos: .userInitiated)

    /// Runs the script and returns the raw `NSAppleEventDescriptor` result.
    private func runAppleScript(_ source: String) async throws -> NSAppleEventDescriptor {
        return try await withCheckedThrowingContinuation { continuation in
            Self.scriptQueue.async {
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

    /// Parses a list of message records (see `recordScript`): `{subject, sender, dateSent,
    /// dateReceived, read, id, accountName, size, Message-ID, …}`.
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
            let size = record.numberOfItems >= 8 ? Int(record.atIndex(8)?.int32Value ?? 0) : 0
            let rfcMessageId = record.numberOfItems >= 9 ? MIMEParser.normalizedMessageID(record.atIndex(9)?.stringValue) : nil

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
                messageId: messageId,
                size: size,
                rfcMessageId: rfcMessageId
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

// MARK: - Batch actions for the rules engine (ARK-202)

/// What the rules engine needs from Mail (lets tests use a fake).
protocol MailActions {
    func apply(_ op: MailBridge.BridgeOp, ids: [Int], mailbox: String, account: String) async throws -> [Int]
    func rfcMessageIDs(ids: [Int], mailbox: String, account: String) async throws -> [Int: String]
    func moveByRFC(_ rfcIDs: [String], from: String, to: String, account: String) async throws -> [String]
    func fetchHeaders(id: Int, mailbox: String, account: String?) async throws -> String
}

extension MailBridge: MailActions {
    enum BridgeOp: Equatable { case move(to: String), delete, setRead(Bool), setFlag(Bool) }

    /// Applies `op` to each message id and returns the ids that worked.
    func apply(_ op: BridgeOp, ids: [Int], mailbox: String, account: String) async throws -> [Int] {
        guard !ids.isEmpty else { return [] }
        let result = try await runAppleScript(Self.applyScript(op, ids: ids, mailbox: mailbox, account: account))
        return listItems(result).map { Int($0.int32Value) }
    }

    /// Message-ID header per message id (to find the message again after a move).
    func rfcMessageIDs(ids: [Int], mailbox: String, account: String) async throws -> [Int: String] {
        guard !ids.isEmpty else { return [:] }
        let result = try await runAppleScript(Self.rfcIDsScript(ids: ids, mailbox: mailbox, account: account))
        var out: [Int: String] = [:]
        for pair in listItems(result) {
            let parts = listItems(pair)
            if parts.count == 2, let rid = parts[1].stringValue { out[Int(parts[0].int32Value)] = rid }
        }
        return out
    }

    /// Moves messages found by Message-ID (undo). Returns the Message-IDs that moved.
    func moveByRFC(_ rfcIDs: [String], from: String, to: String, account: String) async throws -> [String] {
        guard !rfcIDs.isEmpty else { return [] }
        let result = try await runAppleScript(Self.moveByRFCScript(rfcIDs, from: from, to: to, account: account))
        return listItems(result).compactMap(\.stringValue)
    }

    static func applyScript(_ op: BridgeOp, ids: [Int], mailbox: String, account: String) -> String {
        let acc = AppleScriptText.quoted(account)
        let statement: String
        switch op {
        case .move(let to): statement = "move theMsg to (mailbox \(AppleScriptText.quoted(to)) of account \(acc))"
        case .delete: statement = "delete theMsg"
        case .setRead(let value): statement = "set read status of theMsg to \(value)"
        case .setFlag(let value): statement = "set flagged status of theMsg to \(value)"
        }
        return """
        tell application "Mail"
            set okIds to {}
            set theMailbox to mailbox \(AppleScriptText.quoted(mailbox)) of account \(acc)
            repeat with theId in {\(ids.map(String.init).joined(separator: ", "))}
                try
                    set theMsg to (first message of theMailbox whose id is (theId as integer))
                    \(statement)
                    set end of okIds to (theId as integer)
                end try
            end repeat
            return okIds
        end tell
        """
    }

    static func rfcIDsScript(ids: [Int], mailbox: String, account: String) -> String {
        """
        tell application "Mail"
            set out to {}
            set theMailbox to mailbox \(AppleScriptText.quoted(mailbox)) of account \(AppleScriptText.quoted(account))
            repeat with theId in {\(ids.map(String.init).joined(separator: ", "))}
                try
                    set theMsg to (first message of theMailbox whose id is (theId as integer))
                    set end of out to {(theId as integer), (message id of theMsg)}
                end try
            end repeat
            return out
        end tell
        """
    }

    static func moveByRFCScript(_ rfcIDs: [String], from: String, to: String, account: String) -> String {
        let acc = AppleScriptText.quoted(account)
        return """
        tell application "Mail"
            set okIds to {}
            set fromBox to mailbox \(AppleScriptText.quoted(from)) of account \(acc)
            set toBox to mailbox \(AppleScriptText.quoted(to)) of account \(acc)
            repeat with rid in {\(rfcIDs.map(AppleScriptText.quoted).joined(separator: ", "))}
                try
                    move (first message of fromBox whose message id is (rid as text)) to toBox
                    set end of okIds to (rid as text)
                end try
            end repeat
            return okIds
        end tell
        """
    }
}

// MARK: - Sent mail and thread headers (ARK-209)

extension MailBridge: ThreadMailSource {
    func fetchSent(mailbox: String, account: String, offset: Int, limit: Int) async throws -> [SentMessage] {
        let result = try await runAppleScript(Self.rangeScript(mailbox: mailbox, account: account, offset: offset, limit: limit, recipients: true))
        // Same records and same filter as parseMessages, so both lists line up.
        let records = listItems(result).filter { $0.numberOfItems >= 6 }
        return zip(records, parseMessages(from: result, mailbox: mailbox)).map { record, message in
            SentMessage(message: message, to: addresses(record.atIndex(10)), cc: addresses(record.atIndex(11)))
        }
    }

    func fetchAllHeaders(ids: [Int], mailbox: String, account: String) async throws -> [Int: String] {
        guard !ids.isEmpty else { return [:] }
        let result = try await runAppleScript(Self.allHeadersScript(ids: ids, mailbox: mailbox, account: account))
        var out: [Int: String] = [:]
        for pair in listItems(result) {
            let parts = listItems(pair)
            if parts.count == 2, let headers = parts[1].stringValue { out[Int(parts[0].int32Value)] = headers }
        }
        return out
    }

    private func addresses(_ descriptor: NSAppleEventDescriptor?) -> [String] {
        listItems(descriptor).compactMap { $0.stringValue?.lowercased() }.filter { !$0.isEmpty }
    }

    /// One message record appended to `msgList` (read by `parseMessages`): subject, sender, dates,
    /// read, id, account, size, Message-ID and, for sent mail, the To and Cc addresses. Delicate
    /// fields get their own `try`, or one failure drops the whole message (`2c1f01e`).
    static func recordScript(account: String, recipients: Bool = false) -> String {
        var lines = ["set msgSize to 0", "try", "set msgSize to message size of msg", "end try",
                     "set msgRFC to \"\"", "try", "set msgRFC to message id of msg", "end try"]
        var fields = "subject of msg, sender of msg, date sent of msg, date received of msg, read status of msg, id of msg, \(account), msgSize, msgRFC"
        if recipients {
            lines += ["set toList to {}", "try", "set toList to address of to recipients of msg", "end try",
                      "set ccList to {}", "try", "set ccList to address of cc recipients of msg", "end try"]
            fields += ", toList, ccList"
        }
        return (lines + ["set end of msgList to {\(fields)}"]).joined(separator: "\n")
    }

    /// Messages `offset+1 … offset+limit` of a mailbox, newest first, optionally with recipients.
    /// No `try` around the mailbox: a Mail failure must throw, not look like the end (ARK-217).
    static func rangeScript(mailbox: String, account: String, offset: Int, limit: Int, recipients: Bool) -> String {
        let acc = AppleScriptText.quoted(account)
        return """
        tell application "Mail"
            set msgList to {}
            set theMailbox to \(AppleScriptText.mailbox(mailbox, account: account))
            set total to count of (messages of theMailbox)
            set startI to \(offset + 1)
            set endI to \(offset + limit)
            if endI > total then set endI to total
            if startI > endI then return {}
            repeat with msg in (messages startI thru endI of theMailbox)
                try
                    \(recordScript(account: acc, recipients: recipients))
                end try
            end repeat
            return msgList
        end tell
        """
    }

    static func allHeadersScript(ids: [Int], mailbox: String, account: String) -> String {
        """
        tell application "Mail"
            set out to {}
            set theMailbox to mailbox \(AppleScriptText.quoted(mailbox)) of account \(AppleScriptText.quoted(account))
            repeat with theId in {\(ids.map(String.init).joined(separator: ", "))}
                try
                    set theMsg to (first message of theMailbox whose id is (theId as integer))
                    set end of out to {(theId as integer), (all headers of theMsg)}
                end try
            end repeat
            return out
        end tell
        """
    }
}
