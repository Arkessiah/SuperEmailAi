import Testing
import Foundation
@testable import SuperEmailAi

@Test func ruleSurvivesJSONRoundTrip() throws {
    let rule = Rule(name: "Boletines", isEnabled: true, position: 2, matchMode: .any,
                    conditions: [.domainIs("news.com"), .olderThanDays(30), .senderInNewsletters],
                    action: .move(account: "iCloud", mailbox: "Leer luego"),
                    neverSenders: [SenderEntry(address: "jefe@news.com", origin: .correction)])
    let data = try JSONEncoder().encode(rule)
    #expect(try JSONDecoder().decode(Rule.self, from: data) == rule)
}

@Test func onlyMoveArchiveDeleteCountForTheBrake() {
    #expect(RuleAction.move(account: "a", mailbox: "b").isDisplacing)
    #expect(RuleAction.archive.isDisplacing)
    #expect(RuleAction.delete.isDisplacing)
    #expect(!RuleAction.markRead.isDisplacing)
    #expect(!RuleAction.flag.isDisplacing)
}
