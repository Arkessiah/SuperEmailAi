import Foundation
import GRDB
import Testing
@testable import SuperEmailAi

private func store() throws -> MessageStore { try MessageStore(queue: DatabaseQueue()) }

private func mail(_ n: Int, mailbox: String = "INBOX", daysAgo: Double = 1, rfc: String? = nil) -> MailMessage {
    let d = fixedNow.addingTimeInterval(-daysAgo * 86_400)
    var m = MailMessage(id: "iCloud-\(mailbox)-\(n)", subject: "s\(n)", sender: "S", senderAddress: "s\(n)@x.com",
                        dateSent: d, dateReceived: d, isRead: false, mailbox: mailbox, account: "iCloud", messageId: n)
    m.rfcMessageId = rfc
    return m
}

private func storedRFC(_ s: MessageStore, _ id: String) throws -> String? {
    try s.dbQueue!.read { db in try String.fetchOne(db, sql: "SELECT rfcMessageId FROM message WHERE id = ?", arguments: [id]) }
}

@Test func aLaterReadWithoutMessageIDKeepsTheStoredOne() throws {
    let s = try store()
    try s.upsertNow([mail(1, rfc: "a@x")])
    try s.upsertNow([mail(1)])
    #expect(try storedRFC(s, "iCloud-INBOX-1") == "a@x")
    #expect(s.recent(account: "iCloud", mailbox: "INBOX", limit: 5).first?.rfcMessageId == "a@x")
}

@Test func sentMailRemembersItsRecipients() throws {
    let s = try store()
    let sent = mail(1, mailbox: "Sent Messages")
    try s.saveSent([SentMessage(message: sent, to: ["Ana@X.com"], cc: ["bob@x.com"])])
    #expect(s.hasWritten(to: "ana@x.com"))
    #expect(s.hasWritten(to: "BOB@x.com"))
    #expect(!s.hasWritten(to: "carl@x.com"))

    try s.saveSent([SentMessage(message: sent, to: ["carl@x.com"], cc: [])])
    #expect(!s.hasWritten(to: "ana@x.com"))
    #expect(s.hasWritten(to: "carl@x.com"))
}

@Test func deletingASentMessageForgetsItsRecipients() throws {
    let s = try store()
    try s.saveSent([SentMessage(message: mail(1, mailbox: "Sent Messages"), to: ["ana@x.com"], cc: [])])
    try s.dbQueue!.write { db in try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: ["iCloud-Sent Messages-1"]) }
    #expect(!s.hasWritten(to: "ana@x.com"))
}

@Test func onlyRecentMailWithUnreadHeadersIsPending() throws {
    let s = try store()
    try s.upsertNow([mail(1, daysAgo: 1), mail(2, daysAgo: 100), mail(3, mailbox: "Archive", daysAgo: 1)])
    let since = fixedNow.addingTimeInterval(-90 * 86_400)
    #expect(s.needingThreadHeaders(in: [("iCloud", "INBOX")], since: since, limit: 10).map(\.id) == ["iCloud-INBOX-1"])

    try s.saveThreadHeaders(["iCloud-INBOX-1": ThreadHeaders(messageId: nil, inReplyTo: nil, references: [])])
    #expect(s.needingThreadHeaders(in: [("iCloud", "INBOX")], since: since, limit: 10).isEmpty)
}

@Test func aThreadIsFoundFromAnyOfItsMessages() throws {
    let s = try store()
    try s.upsertNow([mail(1, daysAgo: 3, rfc: "m1@x"), mail(2, mailbox: "Sent Messages", daysAgo: 2, rfc: "m2@x"),
                     mail(3, daysAgo: 1, rfc: "m3@x"), mail(4, daysAgo: 1, rfc: "other@x")])
    try s.saveThreadHeaders([
        "iCloud-Sent Messages-2": ThreadHeaders(messageId: "m2@x", inReplyTo: "m1@x", references: ["m1@x"]),
        "iCloud-INBOX-3": ThreadHeaders(messageId: "m3@x", inReplyTo: "m2@x", references: ["m1@x", "m2@x"]),
    ])
    let whole = ["iCloud-INBOX-1", "iCloud-Sent Messages-2", "iCloud-INBOX-3"]
    #expect(s.thread(of: "iCloud-INBOX-1").map(\.id) == whole)
    #expect(s.thread(of: "iCloud-INBOX-3").map(\.id) == whole)
    #expect(s.thread(of: "iCloud-INBOX-4").map(\.id) == ["iCloud-INBOX-4"])
}
