import Testing
import Foundation
import GRDB
@testable import SuperEmailAi

final class FakeMail: MailActions, @unchecked Sendable {
    var failApply = false
    var rfcFor: (Int) -> String? = { "<\($0)@x>" }
    private(set) var applied: [(MailBridge.BridgeOp, [Int])] = []

    func apply(_ op: MailBridge.BridgeOp, ids: [Int], mailbox: String, account: String) async throws -> [Int] {
        if failApply { throw URLError(.cannotConnectToHost) }
        applied.append((op, ids))
        return ids
    }

    func rfcMessageIDs(ids: [Int], mailbox: String, account: String) async throws -> [Int: String] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in rfcFor(id).map { (id, $0) } })
    }

    func moveByRFC(_ rfcIDs: [String], from: String, to: String, account: String) async throws -> [String] { rfcIDs }
}

private func inbox(_ n: Int) -> MailMessage {
    let d = fixedNow.addingTimeInterval(-60)
    return MailMessage(id: "iCloud-INBOX-\(n)", subject: "s\(n)", sender: "S", senderAddress: "s\(n)@x.com",
                       dateSent: d, dateReceived: d, isRead: false, mailbox: "INBOX", account: "iCloud",
                       messageId: n, size: 1)
}

@MainActor
private func setUp(_ action: RuleAction) throws -> (RuleRunner, FakeMail, MessageStore, Rule) {
    let store = try MessageStore(queue: DatabaseQueue()), fake = FakeMail()
    let runner = RuleRunner(store: store, bridge: fake,
                            context: { RuleContext(now: fixedNow, importantSenders: [], newsletterSenders: []) },
                            mailboxesOf: { _ in ["INBOX", "Archive", "Trash"] },
                            onApplied: { _, _ in })
    var rule = Rule(name: "R", isEnabled: true, conditions: [.domainIs("x.com")], action: action)
    rule.enabledAt = fixedNow.addingTimeInterval(-3_600)
    runner.save(rule)
    return (runner, fake, store, rule)
}

@MainActor @Test func actsOnNewMailOnlyOnce() async throws {
    let (runner, fake, _, _) = try setUp(.delete)
    await runner.runCycle(fresh: [inbox(1)], now: fixedNow)
    await runner.runCycle(fresh: [inbox(1)], now: fixedNow)
    #expect(fake.applied.count == 1)
}

@MainActor @Test func brakePausesThenContinueLetsTheBatchThrough() async throws {
    let (runner, fake, _, rule) = try setUp(.delete)
    await runner.runCycle(fresh: (1...26).map(inbox), now: fixedNow)
    #expect(fake.applied.isEmpty)
    #expect(runner.rules[0].pausedReason != nil && runner.notices.count == 1)
    runner.resume(rule.id)
    await runner.runCycle(fresh: [], now: fixedNow)
    #expect(fake.applied.flatMap(\.1).count == 26)
}

@MainActor @Test func withoutMessageIDNothingIsMovedOrDeleted() async throws {
    let (runner, fake, store, _) = try setUp(.delete)
    fake.rfcFor = { _ in nil }
    await runner.runCycle(fresh: [inbox(1)], now: fixedNow)
    #expect(fake.applied.flatMap(\.1).isEmpty)
    #expect(try store.runs().first?.status == .failed)
}

@MainActor @Test func threeFailingCyclesPauseTheRule() async throws {
    let (runner, fake, _, _) = try setUp(.markRead)
    fake.failApply = true
    for n in 1...3 { await runner.runCycle(fresh: [inbox(n)], now: fixedNow) }
    #expect(runner.rules[0].pausedReason == "3 fallos seguidos")
}

@MainActor @Test func undoingOneMessageTeachesNever() async throws {
    let (runner, _, store, rule) = try setUp(.delete)
    await runner.runCycle(fresh: [inbox(1)], now: fixedNow)
    let id = try #require(try store.runs().first?.id)
    await runner.undo(runIds: [id])
    #expect(try store.runs(ids: [id]).first?.status == .undone)
    #expect(runner.rules.first { $0.id == rule.id }?.neverSenders.map(\.address) == ["s1@x.com"])
}

@MainActor @Test func undoingABatchDoesNotLearn() async throws {
    let (runner, _, store, _) = try setUp(.markRead)
    await runner.runCycle(fresh: [inbox(1), inbox(2)], now: fixedNow)
    await runner.undo(runIds: try store.runs().compactMap(\.id))
    #expect(runner.rules[0].neverSenders.isEmpty)
}
