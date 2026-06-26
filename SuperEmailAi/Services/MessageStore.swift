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
}
