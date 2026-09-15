import Foundation

/// What indexing sent mail and threads needs from Mail (a fake in tests).
protocol ThreadMailSource {
    /// Sent mail `offset+1 … offset+limit` of a mailbox (newest first), with its recipients.
    func fetchSent(mailbox: String, account: String, offset: Int, limit: Int) async throws -> [SentMessage]
    /// The full header block per message id; ids Mail can't find are left out.
    func fetchAllHeaders(ids: [Int], mailbox: String, account: String) async throws -> [Int: String]
}

/// Keeps sent mail and thread headers in the index (ARK-209): the latest sent mail each cycle,
/// the whole Sent history in the background, and In-Reply-To/References of the last 90 days.
@MainActor
final class ThreadIndexer {
    static let headerWindow: TimeInterval = 90 * 86_400
    static let recentSentCount = 10   // per account every 2 minutes: enough, and light on Mail
    static let headerBatch = 20

    private let store: MessageStore
    private let mail: ThreadMailSource

    init(store: MessageStore, mail: ThreadMailSource) {
        self.store = store
        self.mail = mail
    }

    /// The Sent mailbox of each account; accounts without one are listed apart (sorted).
    static func sentMailboxes(of accounts: [MailAccount]) -> (found: [(account: String, mailbox: String)], missing: [String]) {
        var found: [(account: String, mailbox: String)] = []
        var missing: [String] = []
        for account in accounts.sorted(by: { $0.name < $1.name }) {
            if let box = MailboxResolver.sent(in: account.mailboxes) {
                found.append((account: account.name, mailbox: box))
            } else {
                missing.append(account.name)
            }
        }
        return (found, missing)
    }

    /// Latest sent mail of each account (the 2-minute cycle). Returns the accounts without Sent.
    @discardableResult
    func syncRecentSent(accounts: [MailAccount]) async -> [String] {
        let (found, missing) = Self.sentMailboxes(of: accounts)
        for box in found {
            guard let sent = try? await mail.fetchSent(mailbox: box.mailbox, account: box.account,
                                                       offset: 0, limit: Self.recentSentCount) else { continue }
            try? store.saveSent(sent)
        }
        return missing
    }

    /// The whole Sent history, page by page, resuming from its cursor (one per account|mailbox).
    /// If Mail fails, it stops without marking anything done. Returns how many it indexed.
    func backfillSent(accounts: [MailAccount], pageSize: Int = 200, pause: UInt64 = 400_000_000,
                      progress: (_ account: String, _ indexed: Int) -> Void = { _, _ in }) async -> Int {
        var indexed = 0
        for box in Self.sentMailboxes(of: accounts).found {
            var (offset, done) = store.backfillCursor(account: box.account, mailbox: box.mailbox)
            var retried = false
            while !done, !Task.isCancelled {
                let page: [SentMessage]
                do {
                    page = try await mail.fetchSent(mailbox: box.mailbox, account: box.account, offset: offset, limit: pageSize)
                    if !page.isEmpty { try store.saveSent(page) }
                } catch { break }
                if page.isEmpty, !retried {   // could be a hiccup rather than the real end
                    retried = true
                    try? await Task.sleep(nanoseconds: pause * 2)
                    continue
                }
                retried = false
                offset += page.count
                done = page.count < pageSize
                do { try store.setBackfillCursorNow(account: box.account, mailbox: box.mailbox, offset: offset, done: done) } catch { break }
                indexed += page.count
                progress(box.account, indexed)
                if !done { try? await Task.sleep(nanoseconds: pause) }
            }
            if Task.isCancelled { break }
        }
        return indexed
    }

    /// Reads In-Reply-To/References of mail from the last 90 days that lacks them (INBOX and Sent),
    /// up to `limit` messages, in batches. Ids Mail can't find any more are stored as read-without-
    /// headers so they aren't asked for again; a failed batch is left for next time.
    /// Returns how many it stored.
    func fillThreadHeaders(accounts: [MailAccount], limit: Int, now: Date = Date()) async -> Int {
        let boxes = Self.sentMailboxes(of: accounts).found + accounts.map { (account: $0.name, mailbox: "INBOX") }
        let pending = store.needingThreadHeaders(in: boxes, since: now.addingTimeInterval(-Self.headerWindow), limit: limit)
        var stored = 0
        for rows in Dictionary(grouping: pending, by: { "\($0.account)|\($0.mailbox)" }).values {
            for start in stride(from: 0, to: rows.count, by: Self.headerBatch) {
                let batch = Array(rows[start..<min(start + Self.headerBatch, rows.count)])
                guard let first = batch.first,
                      let headers = try? await mail.fetchAllHeaders(ids: batch.map(\.messageId), mailbox: first.mailbox,
                                                                   account: first.account) else { continue }
                var parsed: [String: ThreadHeaders] = [:]
                for row in batch {
                    parsed[row.id] = headers[row.messageId].map(MIMEParser.threadHeaders(inHeaders:))
                        ?? ThreadHeaders(messageId: nil, inReplyTo: nil, references: [])
                }
                if (try? store.saveThreadHeaders(parsed)) != nil { stored += parsed.count }
            }
        }
        return stored
    }
}
