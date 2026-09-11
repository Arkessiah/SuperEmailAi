import Testing
import Foundation
import GRDB
@testable import SuperEmailAi

@Test func everyConditionSurvivesTheEditor() {
    let all: [RuleCondition] = [.senderContains("a"), .senderIs("a@b.c"), .domainIs("b.c"), .subjectContains("x"),
                                .olderThanDays(30), .newerThanDays(7), .isRead(true), .isRead(false),
                                .accountIs("iCloud"), .mailboxIs("INBOX"), .largerThanKB(500),
                                .senderInImportant, .senderInNewsletters]
    for c in all { #expect(ConditionDraft(c).condition == c) }
}

@MainActor @Test func reEnablingARuleRestartsItsActivationDate() throws {
    let runner = RuleRunner(store: try MessageStore(queue: DatabaseQueue()), bridge: FakeMail(),
                            context: { RuleContext(now: fixedNow, importantSenders: [], newsletterSenders: []) },
                            mailboxesOf: { _ in [] }, onApplied: { _, _ in })
    var rule = Rule(name: "R", isEnabled: true, conditions: [.domainIs("x.com")], action: .flag)
    rule.enabledAt = Date(timeIntervalSince1970: 0)
    runner.save(rule)
    rule.isEnabled = false
    runner.save(rule)
    #expect(runner.rules[0].enabledAt == nil)
    rule.isEnabled = true
    runner.save(rule)
    #expect((runner.rules[0].enabledAt ?? .distantPast) > Date(timeIntervalSince1970: 0))
}
