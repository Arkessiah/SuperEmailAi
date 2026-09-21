import Foundation
import GRDB
import Testing
@testable import SuperEmailAi

// Fixes from the 2026-09-17 code audit.

@Test func unsubscribeHeadersInTheBodyDontCount() {
    let source = "From: Juan <juan@x.com>\r\nSubject: Te reenvío esto\r\n\r\n---------- Forwarded message ---------\r\nList-Unsubscribe: <https://news.example.com/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n"
    let options = MIMEParser.unsubscribeOptions(fromSource: source)
    #expect(options.link == nil)
    #expect(options.mailto == nil)
    #expect(!options.oneClick)
}

@Test func unsubscribeHeadersInTheHeadersDoCount() {
    let source = "From: N <n@x.com>\r\nList-Unsubscribe: <https://news.example.com/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\nHola"
    let options = MIMEParser.unsubscribeOptions(fromSource: source)
    #expect(options.link?.absoluteString == "https://news.example.com/u")
    #expect(options.oneClick)
}

@Test func recipientsComeFromTheHeadersOnly() {
    #expect(MIMEParser.recipients(fromSource: "From: a@x.com\nTo: Bob <bob@x.com>\n\nTo: otro@x.com\n") == ["bob@x.com"])
}

@Test func knownUnsubscribeOptionsSurviveAnEmptyRead() throws {
    let store = try MessageStore(queue: DatabaseQueue())
    let known = MIMEParser.UnsubscribeOptions(link: URL(string: "https://news.example.com/u"), mailto: nil, oneClick: true)
    try store.saveUnsubscribeOptions(known, for: "news@example.com")
    try store.saveUnsubscribeOptions(MIMEParser.UnsubscribeOptions(link: nil, mailto: nil, oneClick: false), for: "news@example.com")

    let cached = try store.unsubscribeCache()["news@example.com"]
    #expect(cached?.link == "https://news.example.com/u")
    #expect(cached?.oneClick == true)
}

@Test func mailboxNamesKeepComposedEmoji() {
    #expect(AppleScriptText.quoted("👨‍💻 Trabajo") == "\"👨‍💻 Trabajo\"")
    #expect(AppleScriptText.quoted("a\u{0007}b") == "\"ab\"")
}

@Test func markingReadKeepsTheMessageID() {
    var message = msg()
    message.rfcMessageId = "abc@x"
    #expect(message.with(isRead: true).rfcMessageId == "abc@x")
}

// MARK: - Decisions of 2026-09-21

@Test func onlyTheSameMessageIDCountsAsDuplicate() {
    var first = msg(), second = msg(), other = msg()
    first.rfcMessageId = "same@x"
    second.rfcMessageId = "same@x"
    other.rfcMessageId = "different@x"
    #expect(MailManager.duplicateGroups(in: [first, second, other]).map(\.count) == [2])
    // Same sender and subject but no Message-ID read: not treated as duplicates.
    #expect(MailManager.duplicateGroups(in: [msg(), msg()]).isEmpty)
}

@Test func theAlwaysListObeysTheRulesScope() {
    var rule = rule()
    rule.conditions = [.accountIs("Trabajo")]
    rule.alwaysSenders = [SenderEntry(address: "ana@example.com", origin: .manual)]
    #expect(RuleEngine.evaluate(rule, msg(account: "iCloud"), ctx()) == nil)
    #expect(RuleEngine.evaluate(rule, msg(account: "Trabajo"), ctx()) != nil)
}

@Test func timeDependentConditionsAreKnown() {
    #expect(RuleCondition.olderThanDays(30).changesOverTime)
    #expect(RuleCondition.isRead(true).changesOverTime)
    #expect(RuleCondition.senderInNewsletters.changesOverTime)
    #expect(!RuleCondition.subjectContains("factura").changesOverTime)
    #expect(RuleCondition.accountIs("iCloud").isScope)
    #expect(!RuleCondition.senderIs("a@x.com").isScope)
}

@Test func askAIRefusesCategoriesItCannotHonour() {
    // Without a sender, «boletines» would delete matching mail from every sender.
    #expect(MailManager.parseCommand("borra boletines de más de 6 meses no leídos").isEmpty)
    #expect(MailManager.parseCommand("borra los de ofertas@tienda.com de más de 6 meses").senderContains == "ofertas@tienda.com")
}
