import Testing
@testable import SuperEmailAi

@Test func newMailNotificationShowsSenderAndSubject() {
    let text = NotificationText.newMail(msg(name: "Ana García", subject: "Factura"))
    #expect(text == NotificationText(title: "Ana García", body: "Factura", messageID: "iCloud-INBOX-1"))
}

@Test func newMailNotificationNeverShowsEmptyFields() {
    let text = NotificationText.newMail(msg(name: "", subject: ""))
    #expect(text.title == "ana@example.com")
    #expect(text.body == "(sin asunto)")
}

@Test func pausedRuleNotificationNamesTheRule() {
    let text = NotificationText.pausedRule(RuleNotice(ruleId: "r1", ruleName: "Boletines", message: "3 fallos seguidos"))
    #expect(text == NotificationText(title: "Regla en pausa: Boletines", body: "3 fallos seguidos"))
}
