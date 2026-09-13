import Testing
@testable import SuperEmailAi

@Test func findsArchiveAndTrashIgnoringCase() {
    let boxes = ["INBOX", "Sent Messages", "archive", "Deleted Messages"]
    #expect(MailboxResolver.archive(in: boxes) == "archive")
    #expect(MailboxResolver.trash(in: boxes) == "Deleted Messages")
}

@Test func gmailAndSpanishNames() {
    #expect(MailboxResolver.archive(in: ["INBOX", "[Gmail]/All Mail"]) == "[Gmail]/All Mail")
    #expect(MailboxResolver.trash(in: ["Bandeja", "Papelera"]) == "Papelera")
}

@Test func nilWhenTheAccountHasNone() {
    #expect(MailboxResolver.trash(in: ["INBOX"]) == nil)
}

@Test func archiveTargetsPerAccountAndReportsMissing() {
    let boxes = ["iCloud": ["INBOX", "Archive"], "Gmail": ["INBOX", "[Gmail]/All Mail"], "Otra": ["INBOX"]]
    let plan = MailboxResolver.archiveTargets(for: ["iCloud", "Gmail", "Otra"]) { boxes[$0] ?? [] }
    #expect(plan.targets == ["iCloud": "Archive", "Gmail": "[Gmail]/All Mail"])
    #expect(plan.missing == ["Otra"])
}

@Test func quotedEscapesAndStripsControlCharacters() {
    #expect(AppleScriptText.quoted("Caja \"rara\"\\x\n") == "\"Caja \\\"rara\\\"\\\\x\"")
}
