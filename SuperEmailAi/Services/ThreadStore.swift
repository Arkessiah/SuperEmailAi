import Foundation
import GRDB

/// Sent mail and threads in the index (ARK-209).
extension MessageStore {
    /// Saves sent mail with its recipients, replacing the ones stored for those rows.
    func saveSent(_ sent: [SentMessage]) throws {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        guard !sent.isEmpty else { return }
        try dbQueue.write { db in
            for item in sent {
                try MessageRecord(item.message).save(db)
                try db.execute(sql: "DELETE FROM message_recipient WHERE messageRowId = ?", arguments: [item.message.id])
                for (kind, addresses) in [("to", item.to), ("cc", item.cc)] {
                    for address in Set(addresses.map { $0.lowercased() }) where !address.isEmpty {
                        try db.execute(sql: "INSERT OR IGNORE INTO message_recipient (messageRowId, address, kind) VALUES (?, ?, ?)",
                                       arguments: [item.message.id, address, kind])
                    }
                }
            }
        }
    }

    /// Whether any indexed sent mail went to this address (To or Cc).
    func hasWritten(to address: String) -> Bool {
        guard let dbQueue else { return false }
        return (try? dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM message_recipient WHERE address = ?)",
                              arguments: [address.lowercased()]) ?? false
        }) ?? false
    }

    /// Rows of these mailboxes received since `since` whose thread headers are still unread, newest first.
    func needingThreadHeaders(in mailboxes: [(account: String, mailbox: String)], since: Date, limit: Int) -> [MessageRecord] {
        guard let dbQueue, !mailboxes.isEmpty else { return [] }
        let boxes = Array(repeating: "(account = ? AND mailbox = ?)", count: mailboxes.count).joined(separator: " OR ")
        var arguments: StatementArguments = []
        for box in mailboxes { arguments += [box.account, box.mailbox] }
        arguments += [since, limit]
        let sql = """
            SELECT * FROM message WHERE referenceIds IS NULL AND (\(boxes)) AND dateReceived >= ?
            ORDER BY dateReceived DESC LIMIT ?
            """
        return (try? dbQueue.read { db in try MessageRecord.fetchAll(db, sql: sql, arguments: arguments) }) ?? []
    }

    /// Stores read thread headers; an absent header is stored as "" so it isn't read again.
    func saveThreadHeaders(_ headers: [String: ThreadHeaders]) throws {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        guard !headers.isEmpty else { return }
        try dbQueue.write { db in
            for (rowId, h) in headers {
                try db.execute(sql: """
                    UPDATE message SET rfcMessageId = COALESCE(?, rfcMessageId), inReplyTo = ?, referenceIds = ?
                    WHERE id = ?
                    """, arguments: [h.messageId, h.inReplyTo ?? "", Self.referenceField(h.references), rowId])
            }
        }
    }

    /// " id1 id2 ", so a whole id can be matched with instr(); "" when there are none.
    static func referenceField(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ") + " "
    }

    /// The thread of a message: itself, what it answers or references, and what answers or
    /// references it. One hop covers a whole thread when clients send full References. Oldest first.
    func thread(of rowId: String) -> [MessageRecord] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db -> [MessageRecord] in
            guard let row = try Row.fetchOne(db, sql: "SELECT rfcMessageId, inReplyTo, referenceIds FROM message WHERE id = ?",
                                             arguments: [rowId]) else { return [] }
            var ids = Set<String>()
            for column in ["rfcMessageId", "inReplyTo"] {
                if let id: String = row[column], !id.isEmpty { ids.insert(id) }
            }
            let references: String = row["referenceIds"] ?? ""
            ids.formUnion(references.split(separator: " ").map(String.init))

            var clauses = ["id = ?"]
            var arguments: StatementArguments = [rowId]
            for id in ids.sorted() {
                clauses.append("rfcMessageId = ? OR inReplyTo = ? OR instr(referenceIds, ?) > 0")
                arguments += [id, id, " \(id) "]
            }
            let sql = "SELECT * FROM message WHERE \(clauses.map { "(\($0))" }.joined(separator: " OR ")) ORDER BY dateReceived"
            return try MessageRecord.fetchAll(db, sql: sql, arguments: arguments)
        }) ?? []
    }

    /// Synchronous backfill cursor update, for a backfill that reads it again before its next page.
    func setBackfillCursorNow(account: String, mailbox: String, offset: Int, done: Bool) throws {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (key, backfillOffset, done) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET backfillOffset = excluded.backfillOffset, done = excluded.done
                """, arguments: ["\(account)|\(mailbox)", offset, done])
        }
    }
}
