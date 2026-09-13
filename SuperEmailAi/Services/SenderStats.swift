import Foundation
import GRDB

/// Per-sender numbers from the index, for "Boletines" (ARK-203).
struct SenderStat: Identifiable, Equatable {
    let address: String
    let name: String
    let total: Int
    let inInbox: Int
    let read: Int

    var id: String { address }
    var readRatio: Double { total == 0 ? 0 : Double(read) / Double(total) }
}

/// When a sender is suggested for unsubscribing: enough mail and a low read rate.
struct SuggestionCriteria: Equatable {
    var minMessages = 10
    var maxReadPercent = 25

    func suggests(_ s: SenderStat) -> Bool {
        s.total >= minMessages && s.read * 100 <= maxReadPercent * s.total
    }
}

/// How a sender lets you unsubscribe, remembered from its messages' headers.
struct SenderUnsubscribe: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "sender_unsubscribe"

    var senderAddress: String
    var link: String?
    var mailto: String?
    var oneClick: Bool
    var checkedAt: Date
    var unsubscribedAt: Date?

    var options: MIMEParser.UnsubscribeOptions {
        .init(link: link.flatMap(URL.init(string:)), mailto: mailto, oneClick: oneClick)
    }
}

extension MessageStore {
    /// Senders with at least `minMessages` indexed messages, most mail first.
    func senderStats(minMessages: Int = 1) throws -> [SenderStat] {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT senderAddress, MAX(sender) AS name, COUNT(*) AS total,
                       SUM(mailbox = 'INBOX') AS inInbox, SUM(isRead) AS readCount
                FROM message
                GROUP BY senderAddress
                HAVING COUNT(*) >= ?
                ORDER BY total DESC, senderAddress
                """, arguments: [minMessages]).map { row in
                SenderStat(address: row["senderAddress"], name: (row["name"] as String?) ?? "",
                           total: row["total"], inInbox: row["inInbox"], read: row["readCount"])
            }
        }
    }

    /// Remembers how a sender lets you unsubscribe. Keeps `unsubscribedAt` if already set.
    func saveUnsubscribeOptions(_ options: MIMEParser.UnsubscribeOptions, for sender: String,
                                at date: Date = Date()) throws {
        guard let dbQueue, !sender.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sender_unsubscribe (senderAddress, link, mailto, oneClick, checkedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(senderAddress) DO UPDATE SET
                    link = excluded.link, mailto = excluded.mailto,
                    oneClick = excluded.oneClick, checkedAt = excluded.checkedAt
                """, arguments: [sender, options.link?.absoluteString, options.mailto, options.oneClick, date])
        }
    }

    func unsubscribeCache() throws -> [String: SenderUnsubscribe] {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        return try dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try SenderUnsubscribe.fetchAll(db).map { ($0.senderAddress, $0) })
        }
    }

    func markUnsubscribed(_ sender: String, at date: Date = Date()) throws {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sender_unsubscribe SET unsubscribedAt = ? WHERE senderAddress = ?",
                           arguments: [date, sender])
        }
    }

    /// Most recent indexed message from a sender (to read its headers).
    func latestMessage(from sender: String) throws -> MailMessage? {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        return try dbQueue.read { db in
            try MessageRecord.filter(Column("senderAddress") == sender)
                .order(Column("dateReceived").desc)
                .fetchOne(db)?
                .toMailMessage()
        }
    }

    /// A sender's indexed messages still in INBOX (any account), for cleaning up.
    func inboxMessages(from sender: String) throws -> [MailMessage] {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        return try dbQueue.read { db in
            try MessageRecord.filter(Column("senderAddress") == sender && Column("mailbox") == "INBOX")
                .fetchAll(db)
                .map { $0.toMailMessage() }
        }
    }
}
