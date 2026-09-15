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

@Test func everyIndexedReadAsksForTheMessageID() {
    let record = MailBridge.recordScript(account: "\"iCloud\"")
    #expect(record.contains("set msgRFC to message id of msg"))
    #expect(record.contains("id of msg, \"iCloud\", msgSize, msgRFC}"))
    #expect(!record.contains("to recipients"))
}

@Test func sentReadsAlsoBringTheRecipients() {
    let s = MailBridge.sentRangeScript(mailbox: "Sent Messages", account: "Mi \"cuenta\"", offset: 200, limit: 200)
    #expect(s.contains("mailbox \"Sent Messages\" of account \"Mi \\\"cuenta\\\"\""))
    #expect(s.contains("set startI to 201") && s.contains("set endI to 400"))
    #expect(s.contains("address of to recipients of msg") && s.contains("address of cc recipients of msg"))
    #expect(s.contains("msgSize, msgRFC, toList, ccList}"))
}

@Test func headersAreAskedForInOneScriptPerBatch() {
    let s = MailBridge.allHeadersScript(ids: [4, 9], mailbox: "INBOX", account: "iCloud")
    #expect(s.contains("{4, 9}") && s.contains("all headers of theMsg"))
}
