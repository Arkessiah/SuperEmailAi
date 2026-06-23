import Foundation

/// Minimal MIME extractor: pulls the `text/html` part out of a raw RFC822
/// message source and decodes its transfer encoding. Falls back to `nil` when
/// there is no HTML part (callers then show the plain-text body).
enum MIMEParser {

    static func htmlBody(fromSource source: String) -> String? {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let html = findHTML(in: normalized)
        // Guard against returning something that isn't really HTML.
        if let html, html.range(of: "<", options: .caseInsensitive) != nil {
            return html
        }
        return nil
    }

    /// Recursively walks MIME parts (handles nested multipart) and returns the
    /// last text/html leaf found, decoded.
    private static func findHTML(in block: String) -> String? {
        if let boundary = boundary(in: block) {
            let parts = block.components(separatedBy: "--\(boundary)")
            var found: String?
            for part in parts {
                if let html = findHTML(in: part) { found = html }
            }
            return found
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

    private static func boundary(in block: String) -> String? {
        guard let range = block.range(of: #"boundary="?([^";\n]+)"?"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        var value = String(block[range])
        if let eq = value.firstIndex(of: "=") {
            value = String(value[value.index(after: eq)...])
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
