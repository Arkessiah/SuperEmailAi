import Testing
@testable import SuperEmailAi

struct MarkerCase: CustomTestStringConvertible, Sendable {
    let name: String
    let headers: String
    let expected: String?
    var testDescription: String { name }
}

private let person = "From: Ana <ana@example.com>\nTo: yo@example.org\nSubject: Hola\nReturn-Path: <ana@example.com>\n"

@Test(arguments: [
    MarkerCase(name: "persona normal", headers: person, expected: nil),
    MarkerCase(name: "vacío", headers: "", expected: nil),
    MarkerCase(name: "Auto-Submitted auto-replied", headers: person + "Auto-Submitted: auto-replied\n", expected: "Auto-Submitted"),
    MarkerCase(name: "Auto-Submitted con comentario", headers: person + "Auto-Submitted: auto-generated (vacation)\n", expected: "Auto-Submitted"),
    MarkerCase(name: "Auto-Submitted no", headers: person + "Auto-Submitted: no\n", expected: nil),
    MarkerCase(name: "Precedence bulk", headers: person + "Precedence: bulk\n", expected: "Precedence"),
    MarkerCase(name: "Precedence list", headers: person + "Precedence: list\n", expected: "Precedence"),
    MarkerCase(name: "Precedence junk", headers: person + "Precedence: junk\n", expected: "Precedence"),
    MarkerCase(name: "Precedence first-class", headers: person + "Precedence: first-class\n", expected: nil),
    MarkerCase(name: "List-Id", headers: person + "List-Id: Noticias <news.example.com>\n", expected: "List-Id"),
    MarkerCase(name: "List-Unsubscribe", headers: person + "List-Unsubscribe: <https://example.com/u?x=1>\n", expected: "List-Unsubscribe"),
    MarkerCase(name: "list-unsubscribe en minúsculas", headers: person + "list-unsubscribe: <mailto:u@example.com>\n", expected: "List-Unsubscribe"),
    MarkerCase(name: "X-Auto-Response-Suppress All", headers: person + "X-Auto-Response-Suppress: All\n", expected: "X-Auto-Response-Suppress"),
    MarkerCase(name: "X-Auto-Response-Suppress OOF", headers: person + "X-Auto-Response-Suppress: DR, OOF, AutoReply\n", expected: "X-Auto-Response-Suppress"),
    MarkerCase(name: "X-Auto-Response-Suppress DR RN", headers: person + "X-Auto-Response-Suppress: DR, RN\n", expected: nil),
    MarkerCase(name: "X-Autoreply", headers: person + "X-Autoreply: yes\n", expected: "X-Autoreply"),
    MarkerCase(name: "X-Autorespond", headers: person + "X-Autorespond: vacation\n", expected: "X-Autorespond"),
    MarkerCase(name: "Return-Path nulo", headers: "From: MAILER <x@example.com>\nReturn-Path: <>\n", expected: "Return-Path"),
    MarkerCase(name: "cabecera plegada", headers: person + "Auto-Submitted:\n auto-generated\n", expected: "Auto-Submitted"),
    MarkerCase(name: "CRLF", headers: "From: a@example.com\r\nPrecedence: junk\r\n", expected: "Precedence"),
    MarkerCase(name: "solo CR", headers: "From: a@example.com\rList-Id: x\r", expected: "List-Id"),
    MarkerCase(name: "primera línea", headers: "Auto-Submitted: auto-notified\nFrom: a@example.com\n", expected: "Auto-Submitted"),
    MarkerCase(name: "nombre dentro del asunto", headers: "Subject: dudas sobre List-Id: y más\nFrom: a@example.com\n", expected: nil),
    MarkerCase(name: "X-List-Id no es List-Id", headers: person + "X-List-Id: algo\n", expected: nil),
])
func automationMarker(_ c: MarkerCase) {
    #expect(MIMEParser.automationMarker(inHeaders: c.headers) == c.expected)
}
