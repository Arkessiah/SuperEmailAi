import Foundation

/// What a rule needs to know besides the message itself.
struct RuleContext {
    var now: Date
    var importantSenders: Set<String>
    var newsletterSenders: Set<String>
}

struct RuleMatch: Equatable {
    let ruleId: String
    let reason: String
}

/// Pure rule evaluation. "Probar" and real execution call the same functions.
enum RuleEngine {

    /// Order: "never" → "always" → conditions. A move rule only applies to its account.
    static func evaluate(_ rule: Rule, _ m: MailMessage, _ ctx: RuleContext) -> RuleMatch? {
        if case .move(let account, _) = rule.action, account != m.account { return nil }
        let sender = m.senderAddress.lowercased()
        if rule.neverSenders.contains(where: { $0.address.lowercased() == sender }) { return nil }
        if rule.alwaysSenders.contains(where: { $0.address.lowercased() == sender }) {
            return RuleMatch(ruleId: rule.id, reason: "\(m.senderAddress) está en «siempre»")
        }
        guard !rule.conditions.isEmpty else { return nil }
        let results = rule.conditions.map { ($0, holds($0, m, ctx)) }
        let ok = rule.matchMode == .all ? results.allSatisfy(\.1) : results.contains(where: \.1)
        guard ok else { return nil }
        let reason = results.filter(\.1).map { describe($0.0) }.joined(separator: " y ")
        return RuleMatch(ruleId: rule.id, reason: reason)
    }

    /// First enabled, non-paused rule (by position) that matches.
    static func firstMatch(_ rules: [Rule], _ m: MailMessage, _ ctx: RuleContext) -> (rule: Rule, match: RuleMatch)? {
        for rule in rules.sorted(by: { $0.position < $1.position }) where rule.isEnabled && rule.pausedReason == nil {
            if let match = evaluate(rule, m, ctx) { return (rule, match) }
        }
        return nil
    }

    static func holds(_ c: RuleCondition, _ m: MailMessage, _ ctx: RuleContext) -> Bool {
        let day: TimeInterval = 86_400
        switch c {
        case .senderContains(let s): return contains(m.senderAddress, s) || contains(m.sender, s)
        case .senderIs(let s): return m.senderAddress.caseInsensitiveCompare(s.trimmed) == .orderedSame
        case .domainIs(let d):
            let host = m.senderDomain.lowercased(), target = d.trimmed.lowercased()
            return !target.isEmpty && (host == target || host.hasSuffix("." + target))
        case .subjectContains(let s): return contains(m.subject, s)
        case .olderThanDays(let n): return m.dateReceived < ctx.now.addingTimeInterval(-Double(n) * day)
        case .newerThanDays(let n): return m.dateReceived >= ctx.now.addingTimeInterval(-Double(n) * day)
        case .isRead(let r): return m.isRead == r
        case .accountIs(let a): return m.account == a
        case .mailboxIs(let b): return m.mailbox == b
        case .largerThanKB(let kb): return m.size > kb * 1_024
        case .senderInImportant: return ctx.importantSenders.contains(m.senderAddress)
        case .senderInNewsletters: return ctx.newsletterSenders.contains(m.senderAddress)
        }
    }

    /// Human-readable reason for the history (UI text, Spanish).
    static func describe(_ c: RuleCondition) -> String {
        switch c {
        case .senderContains(let s): return "remitente contiene «\(s.trimmed)»"
        case .senderIs(let s): return "remitente es \(s.trimmed)"
        case .domainIs(let d): return "dominio es \(d.trimmed)"
        case .subjectContains(let s): return "asunto contiene «\(s.trimmed)»"
        case .olderThanDays(let n): return "más de \(n) días"
        case .newerThanDays(let n): return "menos de \(n) días"
        case .isRead(let r): return r ? "leído" : "sin leer"
        case .accountIs(let a): return "cuenta \(a)"
        case .mailboxIs(let b): return "buzón \(b)"
        case .largerThanKB(let kb): return "más de \(kb) KB"
        case .senderInImportant: return "remitente en Importantes"
        case .senderInNewsletters: return "remitente en Boletines"
        }
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        let n = needle.trimmed
        return !n.isEmpty && haystack.range(of: n, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
