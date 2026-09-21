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
        // Account and mailbox are the rule's scope: they bind even the «siempre» list.
        let scope = rule.conditions.filter(\.isScope)
        guard scope.allSatisfy({ holds($0, m, ctx) }) else { return nil }

        let sender = m.senderAddress.lowercased()
        if rule.neverSenders.contains(where: { $0.address.lowercased() == sender }) { return nil }
        if rule.alwaysSenders.contains(where: { $0.address.lowercased() == sender }) {
            return RuleMatch(ruleId: rule.id, reason: "\(m.senderAddress) está en «siempre»")
        }
        guard !rule.conditions.isEmpty else { return nil }
        let rest = rule.conditions.filter { !$0.isScope }
        guard !rest.isEmpty else {
            return RuleMatch(ruleId: rule.id, reason: scope.map(describe).joined(separator: " y "))
        }
        let results = rest.map { ($0, holds($0, m, ctx)) }
        let ok = rule.matchMode == .all ? results.allSatisfy(\.1) : results.contains(where: \.1)
        guard ok else { return nil }
        let reason = (scope + results.filter(\.1).map(\.0)).map(describe).joined(separator: " y ")
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

    /// Rules whose displacing actions in one automatic cycle exceed `limit` (safety brake).
    static func brakedRules(_ planned: [(Rule, MailMessage)], limit: Int = 25) -> Set<String> {
        var counts: [String: Int] = [:]
        for (rule, _) in planned where rule.action.isDisplacing { counts[rule.id, default: 0] += 1 }
        return Set(counts.filter { $0.value > limit }.keys)
    }

    /// Identity that survives moves and undo (Mail's internal id may change on a move),
    /// so a message returned by "undo" is not processed again.
    static func stableKey(_ m: MailMessage) -> String {
        "\(m.account)|\(m.senderAddress.lowercased())|\(Int(m.dateReceived.timeIntervalSince1970))|\(m.subject)"
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        let n = needle.trimmed
        return !n.isEmpty && haystack.range(of: n, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
