import Testing
@testable import SuperEmailAi

@Test func sentMailboxIsFoundByNameInAnyCase() {
    #expect(MailboxResolver.sent(in: ["INBOX", "enviados", "Papelera"]) == "enviados")
    #expect(MailboxResolver.sent(in: ["INBOX", "[Gmail]/Sent Mail"]) == "[Gmail]/Sent Mail")
    #expect(MailboxResolver.sent(in: ["INBOX", "Drafts"]) == nil)
}

@Test func threadHeadersAreReadWithFoldedReferences() {
    let headers = "From: Ana <ana@x.com>\nMessage-ID: <m3@x.com>\nIn-Reply-To: <m2@x.com>\nReferences: <m1@x.com>\n <m2@x.com>\nSubject: Re: hola\n"
    #expect(MIMEParser.threadHeaders(inHeaders: headers)
            == ThreadHeaders(messageId: "m3@x.com", inReplyTo: "m2@x.com", references: ["m1@x.com", "m2@x.com"]))
}

@Test func missingThreadHeadersAreEmpty() {
    let headers = "X-Original-Message-ID: <no@x.com>\nMessage-Id: <solo@x.com>\nSubject: hola\n"
    #expect(MIMEParser.threadHeaders(inHeaders: headers) == ThreadHeaders(messageId: "solo@x.com", inReplyTo: nil, references: []))
}

@Test func messageIDsLoseTheirBracketsAndRepeats() {
    #expect(MIMEParser.normalizedMessageID(" <a@x.com> ") == "a@x.com")
    #expect(MIMEParser.normalizedMessageID("") == nil)
    #expect(MIMEParser.messageIDs(in: "<a@x> <b@x> <a@x>") == ["a@x", "b@x"])
    #expect(MIMEParser.messageIDs(in: "a@x b@x") == ["a@x", "b@x"])
}
