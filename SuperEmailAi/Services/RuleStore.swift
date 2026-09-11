import Foundation
import GRDB

enum RuleStoreError: Error { case unavailable }

/// One row of the rules history (90 days).
struct RuleRun: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "rule_run"
    enum Status: String, Codable { case ok, failed, undone, undoFailed }
    enum Trigger: String, Codable { case auto, manual }

    var id: Int64?
    var batchId: String
    var ruleId: String
    var ruleName: String
    var messageKey: String          // RuleEngine.stableKey
    var account: String
    var mailbox: String             // origin mailbox
    var messageId: Int              // Mail id when the action ran
    var rfcMessageId: String?       // Message-ID header, to find it after a move
    var targetMailbox: String?      // where it went (move / archive / trash)
    var sender: String
    var subject: String
    var action: String              // RuleAction.kind
    var reason: String
    var trigger: Trigger
    var status: Status
    var error: String?
    var executedAt: Date
    var undoneAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension RuleAction {
    var kind: String {
        switch self {
        case .move: "move"
        case .archive: "archive"
        case .delete: "delete"
        case .markRead: "markRead"
        case .flag: "flag"
        }
    }
}

extension MessageStore {
    private func queue() throws -> DatabaseQueue {
        guard let dbQueue else { throw RuleStoreError.unavailable }
        return dbQueue
    }

    func loadRules() throws -> [Rule] {
        try queue().read { db in
            try Row.fetchAll(db, sql: "SELECT json FROM rule ORDER BY position").map { row in
                let data: Data = row["json"]
                return try JSONDecoder().decode(Rule.self, from: data)
            }
        }
    }

    func saveRule(_ rule: Rule) throws {
        let json = try JSONEncoder().encode(rule)
        try queue().write { db in
            try db.execute(sql: """
                INSERT INTO rule (id, position, json) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, json = excluded.json
                """, arguments: [rule.id, rule.position, json])
        }
    }

    func deleteRule(id: String) throws {
        try queue().write { db in try db.execute(sql: "DELETE FROM rule WHERE id = ?", arguments: [id]) }
    }

    /// INBOX mail received since `since` (newest first) that no rule has processed yet.
    func unprocessedInbox(since: Date, limit: Int) throws -> [MailMessage] {
        try queue().read { db in
            let processed = Set(try String.fetchAll(db, sql: "SELECT messageKey FROM rule_processed"))
            return try MessageRecord
                .filter(Column("mailbox") == "INBOX" && Column("dateReceived") >= since)
                .order(Column("dateReceived").desc)
                .limit(limit)
                .fetchAll(db)
                .map { $0.toMailMessage() }
                .filter { !processed.contains(RuleEngine.stableKey($0)) }
        }
    }

    func markProcessed(_ keys: [String], at date: Date = Date()) throws {
        guard !keys.isEmpty else { return }
        try queue().write { db in
            for key in keys {
                try db.execute(sql: "INSERT OR REPLACE INTO rule_processed (messageKey, processedAt) VALUES (?, ?)",
                               arguments: [key, date])
            }
        }
    }

    @discardableResult
    func insertRuns(_ runs: [RuleRun]) throws -> [RuleRun] {
        try queue().write { db in
            try runs.map { run in
                var saved = run
                try saved.insert(db)
                return saved
            }
        }
    }

    func runs(ruleId: String? = nil, limit: Int = 500) throws -> [RuleRun] {
        try queue().read { db in
            var request = RuleRun.order(Column("executedAt").desc, Column("id").desc)
            if let ruleId { request = request.filter(Column("ruleId") == ruleId) }
            return try request.limit(limit).fetchAll(db)
        }
    }

    func runs(ids: [Int64]) throws -> [RuleRun] {
        try queue().read { db in try RuleRun.fetchAll(db, keys: ids) }
    }

    func setRunStatus(ids: [Int64], _ status: RuleRun.Status, error: String? = nil, at date: Date = Date()) throws {
        try queue().write { db in
            for id in ids {
                try db.execute(sql: "UPDATE rule_run SET status = ?, error = ?, undoneAt = ? WHERE id = ?",
                               arguments: [status.rawValue, error, status == .undone ? date : nil, id])
            }
        }
    }

    /// History: 90 days. Processed keys: 60 days (twice the 30-day window the cycle looks at).
    func pruneRuleData(now: Date = Date()) throws {
        try queue().write { db in
            try db.execute(sql: "DELETE FROM rule_run WHERE executedAt < ?",
                           arguments: [now.addingTimeInterval(-90 * 86_400)])
            try db.execute(sql: "DELETE FROM rule_processed WHERE processedAt < ?",
                           arguments: [now.addingTimeInterval(-60 * 86_400)])
        }
    }

    /// Indexed messages of one mailbox (newest first), for "Probar" and "apply to existing".
    func indexedMessages(mailbox: String, account: String?, limit: Int = 50_000) throws -> [MailMessage] {
        try queue().read { db in
            var request = MessageRecord.filter(Column("mailbox") == mailbox)
            if let account { request = request.filter(Column("account") == account) }
            return try request.order(Column("dateReceived").desc).limit(limit).fetchAll(db).map { $0.toMailMessage() }
        }
    }
}
