import Foundation

/// Minimal MIME extractor: pulls the `text/html` part out of a raw RFC822
/// message source and decodes its transfer encoding. Falls back to `nil` when
/// there is no HTML part (callers then show the plain-text body).
enum MIMEParser {

    static func htmlBody(fromSource source: String) -> String? {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard let html = findHTML(in: normalized, depth: 0) else { return nil }
        // Only return if it actually looks like HTML.
        return html.contains("<") ? html : nil
    }

    /// Extracts the `To:` recipients (addresses) from the raw source headers.
    static func recipients(fromSource source: String) -> [String] {
        let value = headerValue("To", in: source)
        guard !value.isEmpty else { return [] }

        var result: [String] = []
        var rest = Substring(value)
        while let lt = rest.firstIndex(of: "<"), let gt = rest[lt...].firstIndex(of: ">") {
            let addr = String(rest[rest.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            if addr.contains("@") { result.append(addr) }
            rest = rest[rest.index(after: gt)...]
        }
        if result.isEmpty {
            result = value.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("@") }
        }
        if result.isEmpty { result = [value] }
        return result
    }

    /// Returns a header's value (joining folded continuation lines).
    private static func headerValue(_ name: String, in source: String) -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let range: Range<String.Index>?
        if normalized.lowercased().hasPrefix("\(name.lowercased()):") {
            range = normalized.range(of: "\(name):", options: .caseInsensitive)
        } else {
            range = normalized.range(of: "\n\(name):", options: .caseInsensitive)
        }
        guard let range else { return "" }

        let lines = normalized[range.upperBound...].components(separatedBy: "\n")
        var value = lines.first ?? ""
        var i = 1
        while i < lines.count, let first = lines[i].first, first == " " || first == "\t" {
            value += " " + lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// Message-ID, In-Reply-To and References of a header block (ARK-209), ids without `<>`.
    static func threadHeaders(inHeaders headers: String) -> ThreadHeaders {
        ThreadHeaders(messageId: messageIDs(in: headerValue("Message-ID", in: headers)).first,
                      inReplyTo: messageIDs(in: headerValue("In-Reply-To", in: headers)).first,
                      references: messageIDs(in: headerValue("References", in: headers)))
    }

    /// The `<…>` ids of a header value, without brackets and without repeats; bare ids
    /// (with an @) when there are no brackets.
    static func messageIDs(in value: String) -> [String] {
        var ids: [String] = []
        var rest = value[...]
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let id = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, !ids.contains(id) { ids.append(id) }
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {
            ids = value.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.contains("@") }
        }
        return ids
    }

    /// A Message-ID as Mail's `message id` property gives it, without brackets; nil when empty.
    static func normalizedMessageID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
        return id.isEmpty ? nil : id
    }

    /// Extracts the `List-Unsubscribe` header (the https URL and/or mailto), used
    /// to offer a one-click unsubscribe. Returns the first https URL and mailto found.
    static func listUnsubscribe(fromSource source: String) -> (https: URL?, mailto: String?) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard let headerRange = normalized.range(of: "List-Unsubscribe:", options: .caseInsensitive) else {
            return (nil, nil)
        }

        // Collect the header value, including folded continuation lines.
        let lines = normalized[headerRange.upperBound...].components(separatedBy: "\n")
        var value = lines.first ?? ""
        var i = 1
        while i < lines.count, let first = lines[i].first, first == " " || first == "\t" {
            value += lines[i]
            i += 1
        }

        var https: URL?
        var mailto: String?
        var rest = Substring(value)
        while let lt = rest.firstIndex(of: "<"), let gt = rest[lt...].firstIndex(of: ">") {
            let token = String(rest[rest.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            let lower = token.lowercased()
            if lower.hasPrefix("http"), https == nil {
                https = URL(string: token)
            } else if lower.hasPrefix("mailto:"), mailto == nil {
                mailto = String(token.dropFirst("mailto:".count))
            }
            rest = rest[rest.index(after: gt)...]
        }
        return (https, mailto)
    }

    /// What a newsletter offers to unsubscribe: a link (http/https), a mailto, and whether
    /// the link accepts RFC 8058 one-click (`List-Unsubscribe-Post`, https links only).
    struct UnsubscribeOptions: Equatable {
        var link: URL?
        var mailto: String?
        var oneClick: Bool
    }

    static func unsubscribeOptions(fromSource source: String) -> UnsubscribeOptions {
        let found = listUnsubscribe(fromSource: source)
        let post = headerValue("List-Unsubscribe-Post", in: source).lowercased()
            .replacingOccurrences(of: " ", with: "")
        let oneClick = found.https?.scheme?.lowercased() == "https" && post.contains("list-unsubscribe=one-click")
        return UnsubscribeOptions(link: found.https, mailto: found.mailto, oneClick: oneClick)
    }

    /// Returns the header that marks a message as automated or bulk (mailing
    /// lists, newsletters, bounces, other auto-responders), or `nil` for a normal
    /// person-to-person message. Auto-replies must never answer those (RFC 3834):
    /// it causes backscatter to forged senders and auto-reply loops.
    static func automationMarker(inHeaders headers: String) -> String? {
        let text = headers.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        func value(_ name: String) -> String { headerValue(name, in: text).lowercased() }

        let autoSubmitted = value("Auto-Submitted")
        if !autoSubmitted.isEmpty, !autoSubmitted.hasPrefix("no") { return "Auto-Submitted" }

        let precedence = value("Precedence")
        if ["bulk", "list", "junk"].contains(where: { precedence.hasPrefix($0) }) { return "Precedence" }

        for name in ["List-Id", "List-Unsubscribe", "X-Autoreply", "X-Autorespond"] where !value(name).isEmpty {
            return name
        }

        let suppress = value("X-Auto-Response-Suppress")
        if ["all", "oof", "autoreply"].contains(where: { suppress.contains($0) }) { return "X-Auto-Response-Suppress" }

        if value("Return-Path") == "<>" { return "Return-Path" }

        return nil
    }

    /// Recursively walks MIME parts (handles nested multipart) and returns the
    /// last text/html leaf found, decoded. Recursion is bounded: it only recurses
    /// when the boundary actually splits the block into strictly smaller pieces,
    /// and never deeper than `maxDepth`.
    private static let maxDepth = 12

    private static func findHTML(in block: String, depth: Int) -> String? {
        if depth < maxDepth, let boundary = boundary(in: block) {
            let parts = block.components(separatedBy: "--\(boundary)")
            if parts.count > 1 {
                var found: String?
                for part in parts where part.count < block.count {
                    if let html = findHTML(in: part, depth: depth + 1) { found = html }
                }
                if let found { return found }
                // No HTML in the sub-parts; fall through to leaf handling.
            }
        }

        guard let headerEnd = block.range(of: "\n\n") else { return nil }
        let headers = String(block[..<headerEnd.lowerBound]).lowercased()
        guard headers.contains("text/html") else { return nil }

        var body = String(block[headerEnd.upperBound...])
        if headers.contains("quoted-printable") {
            body = decodeQuotedPrintable(body)
        } else if headers.contains("base64") {
            let cleaned = body.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: cleaned),
               let decoded = String(data: data, encoding: .utf8) {
                body = decoded
            }
        }
        return body
    }

    /// Extracts the MIME boundary value from a headers block (no regex).
    private static func boundary(in block: String) -> String? {
        guard let r = block.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var value = ""
        var inQuote = false
        for ch in block[r.upperBound...] {
            if ch == "\"" {
                if inQuote { break }
                inQuote = true
                continue
            }
            if !inQuote && (ch == ";" || ch == "\n" || ch == "\r") { break }
            if !inQuote && ch == " " && value.isEmpty { continue }
            value.append(ch)
            if value.count > 200 { break }   // safety
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"; \n\r\t"))
        return value.isEmpty ? nil : value
    }

    /// Decodes quoted-printable to a UTF-8 string (byte-accurate so multi-byte
    /// characters survive).
    private static func decodeQuotedPrintable(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "=\n", with: "")
        let input = Array(cleaned.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < input.count {
            if input[i] == 0x3D, i + 2 < input.count {  // '='
                let hex = String(bytes: [input[i + 1], input[i + 2]], encoding: .ascii) ?? ""
                if let byte = UInt8(hex, radix: 16) {
                    bytes.append(byte)
                    i += 3
                    continue
                }
            }
            bytes.append(input[i])
            i += 1
        }
        return String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? cleaned
    }
}
