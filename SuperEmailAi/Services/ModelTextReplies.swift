import Foundation

// MARK: - Quotes, forwards and signatures

extension ModelText {
    /// Keeps what the sender wrote this time: drops `>` lines, the history under an «On … wrote:» /
    /// «El … escribió:» line or an Outlook header block, forwarded mail, the `-- ` signature and
    /// «Enviado desde mi iPhone» footers. A reply written under the quote is kept, and a mail with
    /// nothing of its own (a bare forward) keeps the forwarded content. Empty when nothing is left.
    static func dropQuotesAndSignature(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var kept: [String] = []
        var index = 0
        func hasOwnText() -> Bool { kept.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") || matches(footerPattern, line) { index += 1; continue }
            if line == "--" { break }

            if let afterAttribution = attributionEnd(at: index, in: lines) {
                if let reply = replyBelowQuote(from: afterAttribution, in: lines) { index = reply; continue }
                if hasOwnText() { break }
                index = afterAttribution
                continue
            }
            if let markerLines = originalMessageMarker(at: index, in: lines) {
                if hasOwnText() { break }
                // Nothing of its own: the forwarded mail is the content, its headers included.
                index += markerLines
                while index < lines.count, isHeaderLine(lines[index], headerNames) { kept.append(lines[index]); index += 1 }
                continue
            }
            kept.append(lines[index])
            index += 1
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First unquoted line after a block of `>` lines, when the sender replied under the quote.
    private static func replyBelowQuote(from start: Int, in lines: [String]) -> Int? {
        var sawQuote = false
        for index in start..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(">") { sawQuote = true; continue }
            return sawQuote ? index : nil
        }
        return nil
    }

    /// Index of the line after an attribution line; Gmail wraps long ones onto a second line.
    private static func attributionEnd(at index: Int, in lines: [String]) -> Int? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if matches(attributionPattern, line) { return index + 1 }
        guard index + 1 < lines.count, matches(attributionStartPattern, line) else { return nil }
        let joined = line + " " + lines[index + 1].trimmingCharacters(in: .whitespaces)
        return matches(attributionPattern, joined) ? index + 2 : nil
    }

    /// Marker lines (0 or 1) before the header block of a forwarded or quoted original.
    private static func originalMessageMarker(at index: Int, in lines: [String]) -> Int? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if matches(originalMarkerPattern, line) { return 1 }
        let rest = lines[(index + 1)...]
        if line.count >= 10, line.allSatisfy({ $0 == "_" }),
           let next = rest.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           isHeaderLine(next, fromHeaders) { return 1 }
        if isHeaderLine(line, fromHeaders), let next = rest.first, isHeaderLine(next, sentHeaders) { return 0 }
        return nil
    }

    private static let fromHeaders = ["from", "de", "von", "da"]
    private static let sentHeaders = ["sent", "enviado", "date", "fecha", "gesendet", "envoyé", "inviato", "data"]
    private static let headerNames = fromHeaders + sentHeaders + ["to", "para", "cc", "cco", "bcc", "subject",
                                                                  "asunto", "reply-to", "responder a", "an", "betreff", "objet"]

    /// «From: …», also as «*From:*» when a client turned bold HTML into text.
    private static func isHeaderLine(_ line: String, _ names: [String]) -> Bool {
        let plain = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        return names.contains { plain.hasPrefix($0 + ":") || plain.hasPrefix($0 + " :") }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static let attributionStartPattern = try! NSRegularExpression(
        pattern: "^(on|el|le|am|em|il|op)\\s", options: [.caseInsensitive])
    private static let attributionPattern = try! NSRegularExpression(
        pattern: "^(on|el|le|am|em|il|op)\\s.{0,300}\\s(wrote|escribió|a écrit|schrieb|escreveu|ha scritto|schreef)[^\\n]{0,100}:$",
        options: [.caseInsensitive])
    private static let originalMarkerPattern = try! NSRegularExpression(
        pattern: "^(-{2,}\\s*(forwarded message|mensaje reenviado|message transféré|weitergeleitete nachricht|messaggio inoltrato|mensagem encaminhada|original message|mensaje original|message d'origine|ursprüngliche nachricht|messaggio originale|mensagem original)\\s*-{2,}|(begin forwarded message|inicio del mensaje reenviado|comienzo del mensaje reenviado|début du message réexpédié|anfang der weitergeleiteten nachricht)\\s*:)$",
        options: [.caseInsensitive])
    private static let footerPattern = try! NSRegularExpression(
        pattern: "^((sent from|enviado desde) (my|mi) .{0,40}(iphone|ipad|android|móvil|movil|smartphone|samsung|galaxy|huawei|xiaomi|blackberry|teléfono|telefono|phone|mobile|tablet).{0,30}|(get|obtener|descargar) outlook (for|para) (ios|android)|(sent from|enviado desde) (mail|correo|outlook) (for|para) windows.{0,20})$",
        options: [.caseInsensitive])
}
