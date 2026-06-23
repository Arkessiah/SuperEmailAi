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
