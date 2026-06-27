import Foundation
import GRDB

/// Persistent local index of message metadata (SQLite via GRDB). Phase 1: we
/// write here in parallel to the JSON cache; later phases will read/search/sort
/// from this store and add FTS5 + incremental sync.
struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"

    var id: String          // "account-mailbox-messageId"
    var account: String
    var mailbox: String
    var messageId: Int
    var sender: String
    var senderAddress: String
    var subject: String
    var dateReceived: Date
    var dateSent: Date
    var isRead: Bool
    var size: Int

    init(_ m: MailMessage) {
        id = m.id
        account = m.account
        mailbox = m.mailbox
        messageId = m.messageId
        sender = m.sender
        senderAddress = m.senderAddress
        subject = m.subject
        dateReceived = m.dateReceived
        dateSent = m.dateSent
        isRead = m.isRead
        size = m.size
    }

    func toMailMessage() -> MailMessage {
        MailMessage(
            id: id, subject: subject, sender: sender, senderAddress: senderAddress,
            dateSent: dateSent, dateReceived: dateReceived, isRead: isRead,
            mailbox: mailbox, account: account, messageId: messageId, size: size
        )
    }
}

final class MessageStore {
    static let shared = MessageStore()

    private let dbQueue: DatabaseQueue?

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SuperEmailAi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("messages.sqlite")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Self.migrator.migrate(queue)
            dbQueue = queue
        } catch {
            dbQueue = nil
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("account", .text).notNull()
                t.column("mailbox", .text).notNull()
                t.column("messageId", .integer).notNull()
                t.column("sender", .text).notNull()
                t.column("senderAddress", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("dateReceived", .datetime).notNull()
                t.column("dateSent", .datetime).notNull()
                t.column("isRead", .boolean).notNull()
                t.column("size", .integer).notNull()
            }
            try db.create(index: "idx_message_account_mailbox", on: "message", columns: ["account", "mailbox"])
            try db.create(index: "idx_message_date", on: "message", columns: ["dateReceived"])
            try db.create(index: "idx_message_sender", on: "message", columns: ["senderAddress"])
        }
        migrator.registerMigration("fts5") { db in
            try db.create(virtualTable: "message_ft", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.column("subject")
                t.column("sender")
                t.column("senderAddress")
                t.tokenizer = .unicode61()
            }
        }
        migrator.registerMigration("sync_state") { db in
            try db.create(table: "sync_state") { t in
                t.column("key", .text).primaryKey()          // "account|mailbox"
                t.column("backfillOffset", .integer).notNull().defaults(to: 0)
                t.column("done", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }

    /// Inserts or updates the given messages (by primary key). Runs off the main thread.
    func upsert(_ messages: [MailMessage]) {
        guard let dbQueue, !messages.isEmpty else { return }
        let records = messages.map(MessageRecord.init)
        DispatchQueue.global(qos: .utility).async {
            try? dbQueue.write { db in
                for record in records { try record.save(db) }
            }
        }
    }

    /// Total indexed messages (for verification / debugging).
    func count() -> Int {
        guard let dbQueue else { return 0 }
        return (try? dbQueue.read { db in try MessageRecord.fetchCount(db) }) ?? 0
    }

    // MARK: - Backfill cursor (per account|mailbox)

    /// Where the historical backfill for a view has reached, and whether it's done.
    func backfillCursor(account: String, mailbox: String) -> (offset: Int, done: Bool) {
        guard let dbQueue else { return (0, false) }
        let key = "\(account)|\(mailbox)"
        return (try? dbQueue.read { db -> (Int, Bool) in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT backfillOffset, done FROM sync_state WHERE key = ?", arguments: [key]
            ) else { return (0, false) }
            return (row["backfillOffset"], row["done"])
        }) ?? (0, false)
    }

    /// Persists backfill progress for a view (fire-and-forget, off the main thread).
    func setBackfillCursor(account: String, mailbox: String, offset: Int, done: Bool) {
        guard let dbQueue else { return }
        let key = "\(account)|\(mailbox)"
        DispatchQueue.global(qos: .utility).async {
            try? dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO sync_state (key, backfillOffset, done) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        backfillOffset = excluded.backfillOffset, done = excluded.done
                    """, arguments: [key, offset, done])
            }
        }
    }

    /// Most-recent indexed messages for a view (newest first). `account == nil`
    /// means all accounts. Used for instant display before the AppleScript refresh.
    func recent(account: String?, mailbox: String, limit: Int) -> [MailMessage] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db -> [MailMessage] in
            var request = MessageRecord.filter(Column("mailbox") == mailbox)
            if let account { request = request.filter(Column("account") == account) }
            let records = try request
                .order(Column("dateReceived").desc)
                .limit(limit)
                .fetchAll(db)
            return records.map { $0.toMailMessage() }
        }) ?? []
    }

    /// Full-text search over subject/sender across the whole index (newest first).
    func search(query: String, limit: Int = 1000) -> [MailMessage] {
        guard let dbQueue,
              let pattern = FTS5Pattern(matchingAllTokensIn: query),
              !query.trimmingCharacters(in: .whitespaces).isEmpty
        else { return [] }
        let sql = """
            SELECT message.* FROM message
            JOIN message_ft ON message_ft.rowid = message.rowid
            WHERE message_ft MATCH ?
            ORDER BY message.dateReceived DESC
            LIMIT ?
            """
        return (try? dbQueue.read { db -> [MailMessage] in
            let records = try MessageRecord.fetchAll(db, sql: sql, arguments: [pattern, limit])
            return records.map { $0.toMailMessage() }
        }) ?? []
    }
}
