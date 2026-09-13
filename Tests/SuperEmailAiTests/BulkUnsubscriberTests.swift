import Testing
import Foundation
import GRDB
@testable import SuperEmailAi

final class FakeUnsubscriber: OneClickUnsubscribing, @unchecked Sendable {
    var fail = false
    private(set) var calls: [URL] = []

    func oneClick(_ url: URL) async throws {
        calls.append(url)
        if fail { throw UnsubscribeError.httpStatus(500) }
    }
}

private func message(_ n: Int, from sender: String, mailbox: String = "INBOX") -> MailMessage {
    let d = fixedNow.addingTimeInterval(-Double(n) * 3_600)
    return MailMessage(id: "iCloud-\(mailbox)-\(n)", subject: "s\(n)", sender: "S", senderAddress: sender,
                       dateSent: d, dateReceived: d, isRead: false, mailbox: mailbox, account: "iCloud",
                       messageId: n, size: 1)
}

@MainActor
private func setUp() throws -> (BulkUnsubscriber, FakeMail, FakeUnsubscriber, MessageStore) {
    let store = try MessageStore(queue: DatabaseQueue()), mail = FakeMail(), unsubscriber = FakeUnsubscriber()
    let bulk = BulkUnsubscriber(store: store, mail: mail, unsubscriber: unsubscriber,
                                mailboxesOf: { _ in ["INBOX", "Archive", "Trash"] }, onApplied: { _, _ in })
    return (bulk, mail, unsubscriber, store)
}

@MainActor @Test func oneClickSendersAreUnsubscribedFromTheApp() async throws {
    let (bulk, _, unsubscriber, store) = try setUp()
    try store.saveUnsubscribeOptions(.init(link: URL(string: "https://x.com/u"), mailto: nil, oneClick: true),
                                     for: "news@x.com")
    let result = await bulk.run(senders: ["news@x.com"], cleanup: .none)
    #expect(result.outcomes["news@x.com"] == .unsubscribed)
    #expect(unsubscriber.calls.map(\.absoluteString) == ["https://x.com/u"])
    #expect(try store.unsubscribeCache()["news@x.com"]?.unsubscribedAt != nil)
}

@MainActor @Test func linkOrMailOnlySendersAreLeftForTheUser() async throws {
    let (bulk, _, unsubscriber, store) = try setUp()
    try store.saveUnsubscribeOptions(.init(link: URL(string: "https://a.com/u"), mailto: nil, oneClick: false), for: "a@a.com")
    try store.saveUnsubscribeOptions(.init(link: nil, mailto: "baja@b.com", oneClick: false), for: "b@b.com")
    try store.saveUnsubscribeOptions(.init(link: nil, mailto: nil, oneClick: false), for: "c@c.com")
    let result = await bulk.run(senders: ["a@a.com", "b@b.com", "c@c.com"], cleanup: .none)
    #expect(result.outcomes["a@a.com"] == .manualLink(URL(string: "https://a.com/u")!))
    #expect(result.outcomes["b@b.com"] == .manualMail("baja@b.com"))
    #expect(result.outcomes["c@c.com"] == .noOption)
    #expect(unsubscriber.calls.isEmpty)
}

@MainActor @Test func missingOptionsAreReadFromTheLatestMessageAndRemembered() async throws {
    let (bulk, mail, _, store) = try setUp()
    try store.upsertNow([message(7, from: "news@x.com")])
    mail.headers[7] = "List-Unsubscribe: <https://x.com/u>\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\n"
    let result = await bulk.run(senders: ["news@x.com"], cleanup: .none)
    #expect(result.outcomes["news@x.com"] == .unsubscribed)
    #expect(try store.unsubscribeCache()["news@x.com"]?.options.oneClick == true)
}

@MainActor @Test func aFailedOneClickIsReportedAndNotMarked() async throws {
    let (bulk, _, unsubscriber, store) = try setUp()
    unsubscriber.fail = true
    try store.saveUnsubscribeOptions(.init(link: URL(string: "https://x.com/u"), mailto: nil, oneClick: true),
                                     for: "news@x.com")
    let result = await bulk.run(senders: ["news@x.com"], cleanup: .none)
    guard case .failed = result.outcomes["news@x.com"] else {
        Issue.record("tenía que fallar")
        return
    }
    #expect(try store.unsubscribeCache()["news@x.com"]?.unsubscribedAt == nil)
}

@MainActor @Test func archiveCleansOnlyTheInbox() async throws {
    let (bulk, mail, _, store) = try setUp()
    try store.saveUnsubscribeOptions(.init(link: nil, mailto: nil, oneClick: false), for: "news@x.com")
    try store.upsertNow([message(1, from: "news@x.com"), message(2, from: "news@x.com"),
                         message(3, from: "news@x.com", mailbox: "Carpeta")])
    let result = await bulk.run(senders: ["news@x.com"], cleanup: .archive)
    #expect(result.cleaned == 2)
    #expect(mail.applied.count == 1)
    #expect(mail.applied.first?.0 == .move(to: "Archive"))
    #expect(mail.applied.first?.1.sorted() == [1, 2])
}

@MainActor @Test func deleteSendsTheInboxToTrash() async throws {
    let (bulk, mail, _, store) = try setUp()
    try store.saveUnsubscribeOptions(.init(link: nil, mailto: nil, oneClick: false), for: "news@x.com")
    try store.upsertNow([message(1, from: "news@x.com")])
    let result = await bulk.run(senders: ["news@x.com"], cleanup: .delete)
    #expect(result.cleaned == 1)
    #expect(mail.applied.first?.0 == .delete)
}
