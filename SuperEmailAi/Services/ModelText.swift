import Foundation

/// How much mail text the model gets per task. Provisional: calibrate once ARK-206 picks the engine.
enum ModelTask {
    case classify, summarize, draftReply

    var maxCharacters: Int {
        switch self {
        case .classify: 500
        case .summarize: 2000
        case .draftReply: 3000
        }
    }
}

/// Turns a mail into the text a language model should see: what the reader shows (HTML first),
/// minus hidden text, invisible characters, quoted history, forwards and signatures, cut to a
/// budget. Mail is untrusted input, so this is also a prompt-injection layer — best effort:
/// hiding done through `<style>` classes or off-screen positioning is not detected, which is
/// why prompts must still wrap mail in `promptField` and tell the model it is data.
enum ModelText {
    /// Input beyond this is ignored, to bound the cost on huge newsletters.
    static let maxInputCharacters = 500_000

    static func prepare(html: String?, plain: String, for task: ModelTask) -> String {
        prepare(html: html, plain: plain, maxCharacters: task.maxCharacters)
    }

    /// Tries, in order: the HTML without quotes, the HTML with them (a bare Apple Mail forward
    /// lives inside a blockquote), and the plain part — only when the HTML shows no text, since
    /// the reader shows the HTML and the plain part could say something else.
    static func prepare(html: String?, plain: String, maxCharacters: Int) -> String {
        var sources: [() -> String] = []
        if let html, !html.isEmpty {
            let visible = removeHiddenHTML(String(html.prefix(maxInputCharacters)))
            sources.append { htmlToText(removeElements(in: visible) { name, _ in name == "blockquote" }) }
            sources.append { htmlToText(visible) }
        }
        sources.append { String(plain.prefix(maxInputCharacters)) }
        for source in sources {
            let text = normalizeWhitespace(dropQuotesAndSignature(removeInvisibleCharacters(source())))
            if !text.isEmpty { return truncate(text, maxCharacters: maxCharacters) }
        }
        return ""
    }

    // MARK: - Characters

    /// Removes characters that render as nothing but still reach the model: zero-width and
    /// bidi controls, Unicode tag characters and variation selectors (used to smuggle text),
    /// and control characters other than tab and line breaks.
    static func removeInvisibleCharacters(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisible($0) }))
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: false
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0xAD, 0x34F, 0x61C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E: true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F: true
        case 0xFE00...0xFE0F, 0xFEFF, 0xFFF9...0xFFFB: true
        case 0xE0000...0xE007F, 0xE0100...0xE01EF: true
        default: false
        }
    }

    /// One line per line of text, single spaces, no blank lines, trimmed.
    static func normalizeWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.value {
            case 0x0D, 0x2028, 0x2029: "\n"
            case 0x09, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: " "
            default: scalar
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: " ").joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - Entities

    /// Decodes character references in a single pass, so `&amp;lt;` becomes `&lt;`, not `<`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return replacingMatches(of: entityPattern, in: text) { match, ns in
            decodeEntity(ns.substring(with: match.range(at: 1)))
        }
    }

    /// Replaces each match with what `replacement` returns; nil leaves the match as it was.
    static func replacingMatches(of pattern: NSRegularExpression, in text: String,
                                 _ replacement: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let replaced = replacement(match, ns) else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + replaced
            last = NSMaxRange(match.range)
        }
        return out + ns.substring(from: last)
    }

    private static let entityPattern = try! NSRegularExpression(pattern: "&(#[0-9]{1,8}|#[xX][0-9a-fA-F]{1,7}|[a-zA-Z][a-zA-Z0-9]{1,31});")

    private static func decodeEntity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            guard let value else { return nil }
            let scalar = value == 0 ? nil : Unicode.Scalar(value)
            return String(Character(scalar ?? "\u{FFFD}"))
        }
        return namedEntities[body]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "colon": ":", "semi": ";", "comma": ",", "period": ".", "excl": "!", "quest": "?",
        "num": "#", "dollar": "$", "percnt": "%", "lpar": "(", "rpar": ")", "ast": "*",
        "plus": "+", "sol": "/", "bsol": "\\", "equals": "=", "commat": "@", "lowbar": "_",
        "lsqb": "[", "rsqb": "]", "lcub": "{", "rcub": "}", "verbar": "|", "grave": "`",
        "Tab": "\t", "NewLine": "\n", "hyphen": "-", "dash": "‐", "ndash": "–", "mdash": "—",
        "hellip": "…", "laquo": "«", "raquo": "»", "ldquo": "“", "rdquo": "”", "lsquo": "‘",
        "rsquo": "’", "sbquo": "‚", "bdquo": "„", "bull": "•", "middot": "·", "copy": "©",
        "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "deg": "°", "para": "¶", "sect": "§", "times": "×", "divide": "÷", "iexcl": "¡",
        "iquest": "¿", "ordf": "ª", "ordm": "º", "shy": "\u{AD}", "zwnj": "\u{200C}",
        "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}", "ensp": " ", "emsp": " ",
        "thinsp": " ", "szlig": "ß",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú", "yacute": "ý",
        "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú", "Yacute": "Ý",
        "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "Agrave": "À", "Egrave": "È", "Igrave": "Ì", "Ograve": "Ò", "Ugrave": "Ù",
        "acirc": "â", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "ucirc": "û",
        "Acirc": "Â", "Ecirc": "Ê", "Icirc": "Î", "Ocirc": "Ô", "Ucirc": "Û",
        "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö", "uuml": "ü", "yuml": "ÿ",
        "Auml": "Ä", "Euml": "Ë", "Iuml": "Ï", "Ouml": "Ö", "Uuml": "Ü",
        "atilde": "ã", "otilde": "õ", "ntilde": "ñ", "Atilde": "Ã", "Otilde": "Õ", "Ntilde": "Ñ",
        "ccedil": "ç", "Ccedil": "Ç", "aring": "å", "Aring": "Å", "oslash": "ø", "Oslash": "Ø",
        "aelig": "æ", "AElig": "Æ",
    ]
}

// MARK: - HTML

extension ModelText {
    /// Drops hidden elements (the `hidden` attribute, or inline styles such as `display:none`,
    /// `visibility:hidden`, `font-size:0`, `opacity:0`) with everything nested inside them.
    static func removeHiddenHTML(_ html: String) -> String {
        removeElements(in: html) { _, attributes in isHidden(attributes) }
    }

    /// Drops the elements `drop` selects, with everything nested inside them, plus comments and
    /// never-rendered elements (script, style, head…). An element left unclosed runs to the end,
    /// as it would in a browser; `/>` doesn't close a non-void element either.
    static func removeElements(in html: String, where drop: (_ name: String, _ attributes: [String: String]) -> Bool) -> String {
        let ns = html as NSString
        var out = ""
        var dropping: String?
        var depth = 0
        for token in tokenize(ns) {
            if let name = dropping {
                if token.kind == .tag, token.name == name, !voidElements.contains(name) {
                    depth += token.closing ? -1 : 1
                    if depth == 0 { dropping = nil }
                }
                continue
            }
            switch token.kind {
            case .unrendered: continue
            case .text: out += ns.substring(with: token.range)
            case .tag:
                let raw = ns.substring(with: token.range)
                if !token.closing, drop(token.name, attributes(ofTag: raw)) {
                    if !voidElements.contains(token.name) { dropping = token.name; depth = 1 }
                    continue
                }
                out += raw
            }
        }
        return out
    }

    /// Visible text of an HTML body: blocks and `<br>` become line breaks, source line breaks
    /// are spaces (as a browser renders them), entities are decoded once.
    static func htmlToText(_ html: String) -> String {
        let ns = html as NSString
        var out = ""
        for token in tokenize(ns) {
            switch token.kind {
            case .unrendered: continue
            case .text:
                out += ns.substring(with: token.range)
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            case .tag:
                if lineBreakingElements.contains(token.name) { out += "\n" }
                else if token.name == "td" || token.name == "th" { out += " " }
            }
        }
        return normalizeWhitespace(decodeEntities(out))
    }

    // MARK: Tokens

    private struct Token {
        enum Kind { case text, tag, unrendered }
        let kind: Kind
        let range: NSRange
        var name = ""
        var closing = false
    }

    private static let unrenderedElements = ["script", "style", "head", "title", "template"]
    private static let voidElements: Set = ["area", "base", "br", "col", "embed", "hr", "img", "input",
                                            "link", "meta", "param", "source", "track", "wbr"]
    private static let lineBreakingElements: Set = [
        "br", "p", "div", "li", "ul", "ol", "dl", "dt", "dd", "tr", "table", "caption", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "address", "center", "form",
        "fieldset", "figure", "figcaption", "section", "article", "header", "footer", "nav",
        "aside", "main", "body", "html",
    ]

    /// Comments (unterminated ones run to the end, as in a browser), never-rendered elements,
    /// doctype, and tags whose quoted attribute values may contain `>`.
    private static let tokenPattern: NSRegularExpression = {
        let unrendered = unrenderedElements.map { "<\($0)\\b[^>]*>[\\s\\S]*?(?:</\($0)\\s*>|\\z)" }
        let tag = "</?[a-zA-Z](?:[^>\"']|\"[^\"]*(?:\"|\\z)|'[^']*(?:'|\\z))*(?:>|\\z)"
        // Group 1 = never rendered; anything else is a tag.
        let unrenderedGroup = "(" + (["<!--[\\s\\S]*?(?:-->|\\z)"] + unrendered + ["<[!?][^>]*(?:>|\\z)"]).joined(separator: "|") + ")"
        return try! NSRegularExpression(pattern: unrenderedGroup + "|" + tag, options: [.caseInsensitive])
    }()

    private static func tokenize(_ ns: NSString) -> [Token] {
        var tokens: [Token] = []
        var last = 0
        for match in tokenPattern.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > last {
                tokens.append(Token(kind: .text, range: NSRange(location: last, length: match.range.location - last)))
            }
            last = NSMaxRange(match.range)
            if match.range(at: 1).location != NSNotFound {
                tokens.append(Token(kind: .unrendered, range: match.range))
                continue
            }
            let raw = ns.substring(with: match.range)
            let closing = raw.hasPrefix("</")
            let name = String(raw.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }).lowercased()
            tokens.append(Token(kind: .tag, range: match.range, name: name, closing: closing))
        }
        if last < ns.length { tokens.append(Token(kind: .text, range: NSRange(location: last, length: ns.length - last))) }
        return tokens
    }

    // MARK: Hidden elements

    /// Attributes of an opening tag, names lowercased; the first occurrence wins, as in a browser.
    static func attributes(ofTag tag: String) -> [String: String] {
        let body = String(tag.dropFirst().drop { !$0.isWhitespace && $0 != "/" && $0 != ">" })
        let ns = body as NSString
        var attributes: [String: String] = [:]
        for match in attributePattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            guard attributes[name] == nil else { continue }
            let value = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(ns.substring(with:))
            attributes[name] = value ?? ""
        }
        return attributes
    }

    private static let attributePattern = try! NSRegularExpression(
        pattern: "([^\\s\"'>/=]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+)))?")

    static func isHidden(_ attributes: [String: String]) -> Bool {
        if attributes["hidden"] != nil { return true }
        return attributes["style"].map(hidesContent(style:)) ?? false
    }

    /// Inline CSS that makes an element invisible. Entities, CSS escapes and comments are read
    /// through first, as a browser does.
    static func hidesContent(style: String) -> Bool {
        let css = decodeCSSEscapes(decodeEntities(style))
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
            .lowercased()
        var declarations: [String: String] = [:]
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            declarations[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = parts[1]
                .replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func isZero(_ property: String) -> Bool {
            guard let value = declarations[property] else { return false }
            return Double(value.trimmingCharacters(in: .letters.union(CharacterSet(charactersIn: "%")))) == 0
        }
        return declarations["display"] == "none"
            || ["hidden", "collapse"].contains(declarations["visibility"] ?? "")
            || isZero("font-size") || isZero("opacity")
            || declarations["mso-hide"] == "all"
            || declarations["color"] == "transparent"
            || declarations["overflow"] == "hidden" && ["height", "max-height", "width", "max-width"].contains(where: isZero)
    }

    private static let cssEscapePattern = try! NSRegularExpression(pattern: "\\\\(?:([0-9a-fA-F]{1,6})[ \\t\\n]?|(.))")

    private static func decodeCSSEscapes(_ css: String) -> String {
        guard css.contains("\\") else { return css }
        return replacingMatches(of: cssEscapePattern, in: css) { match, ns in
            guard match.range(at: 1).location != NSNotFound else { return ns.substring(with: match.range(at: 2)) }
            let value = UInt32(ns.substring(with: match.range(at: 1)), radix: 16) ?? 0
            return String(Character(value == 0 ? "\u{FFFD}" : Unicode.Scalar(value) ?? "\u{FFFD}"))
        }
    }
}

// MARK: - Budget and prompt fields

extension ModelText {
    static let truncationMarker = "\n[…]\n"

    /// About two thirds from the start and one third from the end, cut at a space when one is
    /// close, joined by «[…]». Never longer than `maxCharacters`.
    static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        guard text.count > maxCharacters else { return text }
        let available = maxCharacters - truncationMarker.count
        guard available >= 2 else { return String(text.prefix(maxCharacters)) }
        let headCount = available * 2 / 3
        var head = text.prefix(headCount)
        var tail = text.suffix(available - headCount)
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: space, to: head.endIndex) < 40 {
            head = head[..<space]
        }
        if let space = tail.firstIndex(where: \.isWhitespace), tail.distance(from: tail.startIndex, to: space) < 40 {
            tail = tail[tail.index(after: space)...]
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + truncationMarker
            + tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wraps untrusted text as `<name>…</name>` so it can neither close its tag nor open another:
    /// `&`, `<` and `>` are escaped and invisible characters removed. `name` is a fixed identifier.
    static func promptField(_ name: String, _ value: String) -> String {
        precondition(!name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" },
                     "promptField name must be a plain identifier")
        let escaped = removeInvisibleCharacters(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<\(name)>\(escaped)</\(name)>"
    }
}
