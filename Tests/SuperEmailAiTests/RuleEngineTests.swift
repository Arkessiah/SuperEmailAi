import Testing
import Foundation
@testable import SuperEmailAi

let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

func msg(_ sender: String = "ana@example.com", name: String = "Ana", subject: String = "Hola",
         daysAgo: Double = 1, read: Bool = false, account: String = "iCloud",
         mailbox: String = "INBOX", size: Int = 1_000) -> MailMessage {
    let d = fixedNow.addingTimeInterval(-daysAgo * 86_400)
    return MailMessage(id: "\(account)-\(mailbox)-1", subject: subject, sender: name, senderAddress: sender,
                       dateSent: d, dateReceived: d, isRead: read, mailbox: mailbox, account: account,
                       messageId: 1, size: size)
}

func ctx(important: Set<String> = [], newsletters: Set<String> = []) -> RuleContext {
    RuleContext(now: fixedNow, importantSenders: important, newsletterSenders: newsletters)
}

func rule(_ c: [RuleCondition], mode: Rule.MatchMode = .all, action: RuleAction = .markRead,
          position: Int = 0, enabled: Bool = true) -> Rule {
    Rule(name: "r\(position)", isEnabled: enabled, position: position, matchMode: mode, conditions: c, action: action)
}

@Test func senderContainsIgnoresCaseAndLooksAtNameToo() {
    #expect(RuleEngine.evaluate(rule([.senderContains("EXAMPLE")]), msg(), ctx()) != nil)
    #expect(RuleEngine.evaluate(rule([.senderContains("ana")]), msg("x@y.com", name: "Ana"), ctx()) != nil)
}

@Test func emptyTextNeverMatches() {
    #expect(RuleEngine.evaluate(rule([.senderContains("  ")]), msg(), ctx()) == nil)
    #expect(RuleEngine.evaluate(rule([.subjectContains("")]), msg(), ctx()) == nil)
}

@Test func domainMatchesSubdomainsButNotLookalikes() {
    let r = rule([.domainIs("example.com")])
    #expect(RuleEngine.evaluate(r, msg("a@example.com"), ctx()) != nil)
    #expect(RuleEngine.evaluate(r, msg("a@news.example.com"), ctx()) != nil)
    #expect(RuleEngine.evaluate(r, msg("a@evilexample.com"), ctx()) == nil)
}

@Test func ageBoundaries() {
    #expect(RuleEngine.evaluate(rule([.olderThanDays(30)]), msg(daysAgo: 31), ctx()) != nil)
    #expect(RuleEngine.evaluate(rule([.olderThanDays(30)]), msg(daysAgo: 29), ctx()) == nil)
    #expect(RuleEngine.evaluate(rule([.newerThanDays(7)]), msg(daysAgo: 6), ctx()) != nil)
    #expect(RuleEngine.evaluate(rule([.newerThanDays(7)]), msg(daysAgo: 8), ctx()) == nil)
}

@Test func readAccountMailboxAndSize() {
    #expect(RuleEngine.evaluate(rule([.isRead(false)]), msg(read: false), ctx()) != nil)
    #expect(RuleEngine.evaluate(rule([.accountIs("Gmail")]), msg(account: "iCloud"), ctx()) == nil)
    #expect(RuleEngine.evaluate(rule([.mailboxIs("INBOX")]), msg(), ctx()) != nil)
    #expect(RuleEngine.evaluate(rule([.largerThanKB(1)]), msg(size: 2_048), ctx()) != nil)
}

@Test func importantAndNewsletterLists() {
    #expect(RuleEngine.evaluate(rule([.senderInImportant]), msg(), ctx(important: ["ana@example.com"])) != nil)
    #expect(RuleEngine.evaluate(rule([.senderInNewsletters]), msg(), ctx()) == nil)
}

@Test func allVersusAny() {
    let c: [RuleCondition] = [.senderContains("ana"), .subjectContains("factura")]
    #expect(RuleEngine.evaluate(rule(c, mode: .all), msg(), ctx()) == nil)
    #expect(RuleEngine.evaluate(rule(c, mode: .any), msg(), ctx()) != nil)
}

@Test func neverBeatsAlwaysBeatsConditions() {
    var r = rule([.subjectContains("nada que ver")])
    r.alwaysSenders = [SenderEntry(address: "ANA@example.com", origin: .manual)]
    #expect(RuleEngine.evaluate(r, msg(), ctx())?.reason.contains("siempre") == true)
    r.neverSenders = [SenderEntry(address: "ana@example.com", origin: .correction)]
    #expect(RuleEngine.evaluate(r, msg(), ctx()) == nil)
}

@Test func ruleWithoutConditionsOnlyMatchesAlways() {
    #expect(RuleEngine.evaluate(rule([]), msg(), ctx()) == nil)
}

@Test func moveOnlyAppliesToItsAccount() {
    let r = rule([.senderContains("ana")], action: .move(account: "Gmail", mailbox: "X"))
    #expect(RuleEngine.evaluate(r, msg(account: "iCloud"), ctx()) == nil)
    #expect(RuleEngine.evaluate(r, msg(account: "Gmail"), ctx()) != nil)
}

@Test func firstMatchUsesOrderAndSkipsDisabledOrPaused() {
    var paused = rule([.senderContains("ana")], position: 0)
    paused.pausedReason = "freno"
    let disabled = rule([.senderContains("ana")], position: 1, enabled: false)
    let second = rule([.senderContains("ana")], position: 3)
    let first = rule([.senderContains("ana")], position: 2)
    let hit = RuleEngine.firstMatch([second, disabled, paused, first], msg(), ctx())
    #expect(hit?.rule.id == first.id)
}

@Test func reasonNamesTheMatchedConditions() {
    let m = RuleEngine.evaluate(rule([.domainIs("example.com"), .isRead(false)]), msg(), ctx())
    #expect(m?.reason == "dominio es example.com y sin leer")
}
