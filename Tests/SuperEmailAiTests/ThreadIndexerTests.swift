import Foundation
import GRDB
import Testing
@testable import SuperEmailAi

final class FakeThreadMail: ThreadMailSource, @unchecked Sendable {
    var sent: [String: [SentMessage]] = [:]   // "account|mailbox" → newest first
    var headers: [Int: String] = [:]
    var failSent = false
    var failHeaders = false
    var failHeadersFor: Set<String> = []   // accounts whose headers always fail
    private(set) var headerRequests: [[Int]] = []

    func fetchSent(mailbox: String, account: String, offset: Int, limit: Int) async throws -> [SentMessage] {
        if failSent { throw URLError(.cannotConnectToHost) }
        let all = sent["\(account)|\(mailbox)"] ?? []
        guard offset < all.count else { return [] }
        return Array(all[offset..<min(offset + limit, all.count)])
    }

    func fetchAllHeaders(ids: [Int], mailbox: String, account: String) async throws -> [Int: String] {
        if failHeaders || failHeadersFor.contains(account) { throw URLError(.cannotConnectToHost) }
        headerRequests.append(ids)
        return headers.filter { ids.contains($0.key) }
    }
}

private let accounts = [MailAccount(name: "iCloud", mailboxes: ["INBOX", "Sent Messages"]),
                        MailAccount(name: "Trabajo", mailboxes: ["INBOX"])]

private func row(_ n: Int, mailbox: String = "INBOX", daysAgo: Double = 1, account: String = "iCloud") -> MailMessage {
    let d = fixedNow.addingTimeInterval(-daysAgo * 86_400)
    return MailMessage(id: "\(account)-\(mailbox)-\(n)", subject: "s\(n)", sender: "S", senderAddress: "s\(n)@x.com",
                       dateSent: d, dateReceived: d, isRead: true, mailbox: mailbox, account: account, messageId: n)
}

private func sent(_ n: Int, to: String) -> SentMessage {
    SentMessage(message: row(n, mailbox: "Sent Messages"), to: [to], cc: [])
}

private func inReplyTo(_ store: MessageStore, _ id: String) throws -> String? {
    try store.dbQueue!.read { db in try String.fetchOne(db, sql: "SELECT inReplyTo FROM message WHERE id = ?", arguments: [id]) }
}

@Test @MainActor func recentSentMailIsIndexedAndAccountsWithoutSentAreReported() async throws {
    let store = try MessageStore(queue: DatabaseQueue()), mail = FakeThreadMail()
    mail.sent["iCloud|Sent Messages"] = [sent(1, to: "ana@x.com")]
    let missing = await ThreadIndexer(store: store, mail: mail).syncRecentSent(accounts: accounts)
    #expect(missing == ["Trabajo"])
    #expect(store.hasWritten(to: "ana@x.com"))
}

@Test @MainActor func sentHistoryIsWalkedPageByPageAndNotAgain() async throws {
    let store = try MessageStore(queue: DatabaseQueue()), mail = FakeThreadMail()
    mail.sent["iCloud|Sent Messages"] = (1...5).map { sent($0, to: "p\($0)@x.com") }
    let indexer = ThreadIndexer(store: store, mail: mail)
    #expect(await indexer.backfillSent(accounts: accounts, pageSize: 2, pause: 0) == 5)
    #expect((1...5).allSatisfy { store.hasWritten(to: "p\($0)@x.com") })
    #expect(store.backfillCursor(account: "iCloud", mailbox: "Sent Messages") == (5, true))
    #expect(await indexer.backfillSent(accounts: accounts, pageSize: 2, pause: 0) == 0)
}

@Test @MainActor func aFailingMailStopsTheBackfillWithoutMarkingItDone() async throws {
    let store = try MessageStore(queue: DatabaseQueue()), mail = FakeThreadMail()
    mail.failSent = true
    #expect(await ThreadIndexer(store: store, mail: mail).backfillSent(accounts: accounts, pageSize: 2, pause: 0) == 0)
    #expect(store.backfillCursor(account: "iCloud", mailbox: "Sent Messages").done == false)
}

@Test @MainActor func threadHeadersAreReadForRecentMailOnly() async throws {
    let store = try MessageStore(queue: DatabaseQueue()), mail = FakeThreadMail()
    try store.upsertNow([row(1, daysAgo: 1), row(2, daysAgo: 100)])
    mail.headers[1] = "Message-ID: <m1@x>\nIn-Reply-To: <m0@x>\nReferences: <m0@x>\n"
    #expect(await ThreadIndexer(store: store, mail: mail).fillThreadHeaders(accounts: accounts, limit: 50, now: fixedNow) == 1)
    #expect(mail.headerRequests == [[1]])
    #expect(try inReplyTo(store, "iCloud-INBOX-1") == "m0@x")
}

@Test @MainActor func aFailingAccountDoesNotStarveTheOthers() async throws {
    let store = try MessageStore(queue: DatabaseQueue()), mail = FakeThreadMail()
    // The failing account has far more pending mail than the limit: without a share each, it
    // would take the whole batch every cycle and «Trabajo» would never be read.
    try store.upsertNow((1...40).map { row($0, account: "iCloud") } + [row(1, account: "Trabajo")])
    mail.failHeadersFor = ["iCloud"]
    mail.headers[1] = "Message-ID: <t1@x>\n"

    let indexer = ThreadIndexer(store: store, mail: mail)
    #expect(await indexer.fillThreadHeaders(accounts: accounts, limit: 20, now: fixedNow) == 1)
    #expect(try inReplyTo(store, "Trabajo-INBOX-1") == "")
}

@Test @MainActor func goneMailIsMarkedAndFailedBatchesAreRetried() async throws {
    let store = try MessageStore(queue: DatabaseQueue()), mail = FakeThreadMail()
    let indexer = ThreadIndexer(store: store, mail: mail)
    try store.upsertNow([row(1), row(2)])
    mail.headers[1] = "Message-ID: <m1@x>\n"
    #expect(await indexer.fillThreadHeaders(accounts: accounts, limit: 50, now: fixedNow) == 2)
    #expect(try inReplyTo(store, "iCloud-INBOX-2") == "")

    try store.upsertNow([row(3)])
    mail.failHeaders = true
    #expect(await indexer.fillThreadHeaders(accounts: accounts, limit: 50, now: fixedNow) == 0)
    mail.failHeaders = false
    #expect(await indexer.fillThreadHeaders(accounts: accounts, limit: 50, now: fixedNow) == 1)
}
