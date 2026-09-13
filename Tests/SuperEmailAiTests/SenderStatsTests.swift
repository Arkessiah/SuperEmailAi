import Testing
import Foundation
import GRDB
@testable import SuperEmailAi

private func store() throws -> MessageStore { try MessageStore(queue: DatabaseQueue()) }

private func mail(_ n: Int, from sender: String, read: Bool, mailbox: String = "INBOX",
                  account: String = "iCloud") -> MailMessage {
    let d = fixedNow.addingTimeInterval(-Double(n) * 3_600)
    return MailMessage(id: "\(account)-\(mailbox)-\(n)", subject: "s\(n)", sender: "Nombre \(sender)",
                       senderAddress: sender, dateSent: d, dateReceived: d, isRead: read, mailbox: mailbox,
                       account: account, messageId: n, size: 1)
}

// MARK: - Stats and suggestions

@Test func statsCountTotalInboxAndRead() throws {
    let s = try store()
    try s.upsertNow([
        mail(1, from: "news@x.com", read: false), mail(2, from: "news@x.com", read: false),
        mail(3, from: "news@x.com", read: true), mail(4, from: "news@x.com", read: false, mailbox: "Archive"),
        mail(5, from: "ana@y.com", read: true),
    ])
    let stats = try s.senderStats()
    let news = try #require(stats.first { $0.address == "news@x.com" })
    #expect(news.total == 4 && news.inInbox == 3 && news.read == 1)
    #expect(news.readRatio == 0.25)
    #expect(stats.first?.address == "news@x.com")
}

@Test func minimumMessagesFiltersSmallSenders() throws {
    let s = try store()
    try s.upsertNow([mail(1, from: "a@x.com", read: false), mail(2, from: "b@x.com", read: false),
                     mail(3, from: "b@x.com", read: false)])
    #expect(try s.senderStats(minMessages: 2).map(\.address) == ["b@x.com"])
}

@Test func suggestionNeedsVolumeAndLowReadRate() {
    let criteria = SuggestionCriteria(minMessages: 10, maxReadPercent: 25)
    #expect(criteria.suggests(SenderStat(address: "a", name: "A", total: 10, inInbox: 10, read: 2)))
    #expect(!criteria.suggests(SenderStat(address: "a", name: "A", total: 9, inInbox: 9, read: 0)))
    #expect(!criteria.suggests(SenderStat(address: "a", name: "A", total: 20, inInbox: 20, read: 6)))
    #expect(criteria.suggests(SenderStat(address: "a", name: "A", total: 20, inInbox: 20, read: 5)))
}

// MARK: - How each sender lets you unsubscribe

@Test func unsubscribeOptionsAreRememberedPerSender() throws {
    let s = try store()
    try s.saveUnsubscribeOptions(.init(link: URL(string: "https://x.com/u"), mailto: nil, oneClick: true),
                                 for: "news@x.com", at: fixedNow)
    let cached = try #require(try s.unsubscribeCache()["news@x.com"])
    #expect(cached.options.oneClick && cached.options.link?.absoluteString == "https://x.com/u")
    #expect(cached.unsubscribedAt == nil)
}

@Test func savingAgainKeepsTheUnsubscribeDate() throws {
    let s = try store()
    let options = MIMEParser.UnsubscribeOptions(link: URL(string: "https://x.com/u"), mailto: nil, oneClick: true)
    try s.saveUnsubscribeOptions(options, for: "news@x.com", at: fixedNow)
    try s.markUnsubscribed("news@x.com", at: fixedNow)
    try s.saveUnsubscribeOptions(options, for: "news@x.com", at: fixedNow.addingTimeInterval(60))
    #expect(try s.unsubscribeCache()["news@x.com"]?.unsubscribedAt == fixedNow)
}

@Test func sendersWithoutOptionsAreRememberedToo() throws {
    let s = try store()
    try s.saveUnsubscribeOptions(.init(link: nil, mailto: nil, oneClick: false), for: "ana@y.com", at: fixedNow)
    let cached = try #require(try s.unsubscribeCache()["ana@y.com"])
    #expect(cached.options.link == nil && cached.options.mailto == nil && !cached.options.oneClick)
}

@Test func latestMessageAndInboxMessagesOfASender() throws {
    let s = try store()
    try s.upsertNow([mail(1, from: "news@x.com", read: false), mail(2, from: "news@x.com", read: false),
                     mail(3, from: "news@x.com", read: false, mailbox: "Archive"), mail(4, from: "ana@y.com", read: false)])
    #expect(try s.latestMessage(from: "news@x.com")?.messageId == 1)
    #expect(try s.inboxMessages(from: "news@x.com").map(\.messageId).sorted() == [1, 2])
}
