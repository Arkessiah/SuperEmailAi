import Testing
import Foundation
import GRDB
@testable import SuperEmailAi

private func store() throws -> MessageStore { try MessageStore(queue: DatabaseQueue()) }

private func m(_ n: Int, daysAgo: Double, mailbox: String = "INBOX") -> MailMessage {
    let d = fixedNow.addingTimeInterval(-daysAgo * 86_400)
    return MailMessage(id: "iCloud-\(mailbox)-\(n)", subject: "s\(n)", sender: "S", senderAddress: "s\(n)@x.com",
                       dateSent: d, dateReceived: d, isRead: false, mailbox: mailbox, account: "iCloud",
                       messageId: n, size: 1)
}

private func run(_ ruleId: String, at date: Date = fixedNow) -> RuleRun {
    RuleRun(id: nil, batchId: "b", ruleId: ruleId, ruleName: ruleId, messageKey: "k", account: "iCloud",
            mailbox: "INBOX", messageId: 1, rfcMessageId: "<a@b>", targetMailbox: "Trash", sender: "a@b.com",
            subject: "s", action: "delete", reason: "r", trigger: .auto, status: .ok, error: nil,
            executedAt: date, undoneAt: nil)
}

@Test func rulesComeBackInOrder() throws {
    let s = try store()
    try s.saveRule(Rule(name: "B", position: 1, action: .delete))
    try s.saveRule(Rule(name: "A", position: 0, action: .flag))
    #expect(try s.loadRules().map(\.name) == ["A", "B"])
}

@Test func unprocessedInboxSkipsProcessedOldAndOtherMailboxes() throws {
    let s = try store()
    try s.upsertNow([m(1, daysAgo: 1), m(2, daysAgo: 40), m(3, daysAgo: 1, mailbox: "Sent"), m(4, daysAgo: 2)])
    try s.markProcessed([RuleEngine.stableKey(m(4, daysAgo: 2))])
    let got = try s.unprocessedInbox(since: fixedNow.addingTimeInterval(-30 * 86_400), limit: 100)
    #expect(got.map(\.messageId) == [1])
}

@Test func runsCanBeListedAndMarkedUndone() throws {
    let s = try store()
    let saved = try s.insertRuns([run("r1"), run("r2")])
    #expect(try s.runs(ruleId: "r1").count == 1)
    let id = try #require(saved[0].id)
    try s.setRunStatus(ids: [id], .undone)
    let after = try s.runs(ids: [id])[0]
    #expect(after.status == .undone && after.undoneAt != nil)
}

@Test func pruneDropsHistoryOlderThanNinetyDays() throws {
    let s = try store()
    try s.insertRuns([run("r", at: fixedNow.addingTimeInterval(-100 * 86_400)), run("r")])
    try s.pruneRuleData(now: fixedNow)
    #expect(try s.runs().count == 1)
}
