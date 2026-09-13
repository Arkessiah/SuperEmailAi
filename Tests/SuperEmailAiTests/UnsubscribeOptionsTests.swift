import Testing
@testable import SuperEmailAi

private let base = "From: News <news@example.com>\nSubject: Boletín\n"

@Test func oneClickNeedsThePostHeaderAndAnHTTPSLink() {
    let src = base + "List-Unsubscribe: <https://example.com/u?id=1>, <mailto:u@example.com>\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\n\ncuerpo"
    let o = MIMEParser.unsubscribeOptions(fromSource: src)
    #expect(o.oneClick)
    #expect(o.link?.absoluteString == "https://example.com/u?id=1")
    #expect(o.mailto == "u@example.com")
}

@Test func noPostHeaderMeansNoOneClick() {
    let o = MIMEParser.unsubscribeOptions(fromSource: base + "List-Unsubscribe: <https://example.com/u>\n\n")
    #expect(!o.oneClick)
    #expect(o.link != nil)
}

@Test func plainHTTPLinkIsNeverOneClick() {
    let src = base + "List-Unsubscribe: <http://example.com/u>\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\n\n"
    let o = MIMEParser.unsubscribeOptions(fromSource: src)
    #expect(!o.oneClick)
    #expect(o.link?.scheme == "http")
}

@Test func mailtoOnly() {
    let o = MIMEParser.unsubscribeOptions(fromSource: base + "List-Unsubscribe: <mailto:baja@example.com?subject=unsubscribe>\n\n")
    #expect(o.link == nil && !o.oneClick)
    #expect(o.mailto == "baja@example.com?subject=unsubscribe")
}

@Test func postHeaderIsCaseInsensitiveAndMayBeFolded() {
    let src = base + "List-Unsubscribe: <https://example.com/u>\nlist-unsubscribe-post:\n List-Unsubscribe=One-Click\n\n"
    #expect(MIMEParser.unsubscribeOptions(fromSource: src).oneClick)
}

@Test func noUnsubscribeHeaders() {
    #expect(MIMEParser.unsubscribeOptions(fromSource: base + "\n") == .init(link: nil, mailto: nil, oneClick: false))
}
