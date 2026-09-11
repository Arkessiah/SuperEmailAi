import Testing
@testable import SuperEmailAi

@Test func applyScriptEscapesNamesAndReturnsWhatWorked() {
    let s = MailBridge.applyScript(.move(to: "Leer \"luego\""), ids: [3, 7], mailbox: "INBOX", account: "Mi cuenta")
    #expect(s.contains("mailbox \"INBOX\" of account \"Mi cuenta\""))
    #expect(s.contains("move theMsg to (mailbox \"Leer \\\"luego\\\"\" of account \"Mi cuenta\")"))
    #expect(s.contains("{3, 7}"))
    #expect(s.contains("set end of okIds to (theId as integer)"))
}

@Test func flagAndReadStatements() {
    #expect(MailBridge.applyScript(.setFlag(true), ids: [1], mailbox: "INBOX", account: "a").contains("set flagged status of theMsg to true"))
    #expect(MailBridge.applyScript(.setRead(false), ids: [1], mailbox: "INBOX", account: "a").contains("set read status of theMsg to false"))
}

@Test func moveByRFCQuotesMessageIDs() {
    #expect(MailBridge.moveByRFCScript(["a\"b@x"], from: "Trash", to: "INBOX", account: "a").contains("{\"a\\\"b@x\"}"))
}
