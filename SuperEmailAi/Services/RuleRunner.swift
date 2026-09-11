import SwiftUI

/// A pause the user has to see (safety brake or repeated failures).
struct RuleNotice: Identifiable, Equatable {
    let id = UUID()
    let ruleId: String
    let ruleName: String
    let message: String
}

enum RuleRunnerError: LocalizedError {
    case noMailbox(kind: String, account: String)
    var errorDescription: String? {
        switch self {
        case .noMailbox(let kind, let account): "No encuentro el buzón «\(kind)» en la cuenta \(account)"
        }
    }
}

/// Runs rules: automatic cycle over new INBOX mail, "Probar", apply to existing, undo.
@MainActor
final class RuleRunner: ObservableObject {
    @Published private(set) var rules: [Rule] = []
    @Published private(set) var notices: [RuleNotice] = []
    @Published private(set) var history: [RuleRun] = []
    @Published var lastError: String?

    static let brakeLimit = 25
    static let failureLimit = 3
    static let candidateWindow: TimeInterval = 30 * 86_400

    private let store: MessageStore
    private let bridge: MailActions
    private let context: () -> RuleContext
    private let mailboxesOf: (String) -> [String]
    private let onApplied: (_ removedIds: [String], _ readIds: [String]) -> Void
    private var bypassBrakeOnce: Set<String> = []
    private var isRunning = false

    init(store: MessageStore = .shared, bridge: MailActions = MailBridge.shared,
         context: @escaping () -> RuleContext,
         mailboxesOf: @escaping (String) -> [String],
         onApplied: @escaping ([String], [String]) -> Void) {
        self.store = store
        self.bridge = bridge
        self.context = context
        self.mailboxesOf = mailboxesOf
        self.onApplied = onApplied
    }

    var hasActiveRules: Bool { rules.contains { $0.isEnabled && $0.pausedReason == nil } }

    // MARK: - Rules

    func load() {
        do { rules = try store.loadRules() } catch { lastError = error.localizedDescription }
    }

    /// Saves from the editor. `enabledAt` restarts whenever the rule becomes enabled, so
    /// mail received while it was disabled is never processed automatically.
    func save(_ rule: Rule) {
        var r = rule
        let previous = rules.first { $0.id == r.id }
        if previous == nil { r.position = (rules.map(\.position).max() ?? -1) + 1 }
        if !r.isEnabled {
            r.enabledAt = nil
        } else if previous == nil {
            r.enabledAt = r.enabledAt ?? Date()
        } else if previous?.isEnabled == false {
            r.enabledAt = Date()            // an existing rule re-enabled starts fresh
        }
        persist(r)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard var r = rules.first(where: { $0.id == id }) else { return }
        r.isEnabled = on
        r.enabledAt = on ? Date() : nil
        if on { r.pausedReason = nil; r.consecutiveFailures = 0 }
        persist(r)
    }

    /// "Continuar" after a pause: the pending batch goes through once.
    func resume(_ id: String) {
        guard var r = rules.first(where: { $0.id == id }) else { return }
        r.pausedReason = nil
        r.consecutiveFailures = 0
        bypassBrakeOnce.insert(id)
        persist(r)
        notices.removeAll { $0.ruleId == id }
    }

    func delete(_ id: String) {
        do { try store.deleteRule(id: id) } catch { lastError = error.localizedDescription; return }
        rules.removeAll { $0.id == id }
        notices.removeAll { $0.ruleId == id }
    }

    func reorder(from source: IndexSet, to destination: Int) {
        var list = rules
        list.move(fromOffsets: source, toOffset: destination)
        for i in list.indices { list[i].position = i }
        list.forEach(persist)
    }

    func loadHistory(ruleId: String? = nil) {
        history = (try? store.runs(ruleId: ruleId)) ?? []
    }

    private func persist(_ r: Rule) {
        do { try store.saveRule(r) } catch { lastError = error.localizedDescription; return }
        if let i = rules.firstIndex(where: { $0.id == r.id }) { rules[i] = r } else { rules.append(r) }
        rules.sort { $0.position < $1.position }
    }

    // MARK: - Probar / apply to existing

    /// The rule's mailbox condition (else INBOX) and account (condition or move target).
    static func scope(of rule: Rule) -> (mailbox: String, account: String?) {
        var mailbox = "INBOX"
        var account: String?
        for c in rule.conditions {
            if case .mailboxIs(let b) = c { mailbox = b }
            if case .accountIs(let a) = c { account = a }
        }
        if case .move(let a, _) = rule.action { account = a }
        return (mailbox, account)
    }

    /// Same evaluation as real runs, over the index, off the main thread.
    func preview(_ rule: Rule) async -> (count: Int, sample: [MailMessage]) {
        let hits = await matches(of: rule)
        return (hits.count, hits.prefix(50).map { $0.0 })
    }

    /// Manual run over indexed history, after the user confirmed the count (no brake).
    func applyToExisting(_ rule: Rule) async -> Int {
        let hits = await matches(of: rule)
        let runs = await execute(hits.map { (rule, $0.1, $0.0) }, trigger: .manual)
        return runs.filter { $0.status == .ok }.count
    }

    private func matches(of rule: Rule) async -> [(MailMessage, RuleMatch)] {
        let ctx = context(), store = store
        let (mailbox, account) = Self.scope(of: rule)
        return await Task.detached(priority: .userInitiated) {
            let messages = (try? store.indexedMessages(mailbox: mailbox, account: account)) ?? []
            return messages.compactMap { m in RuleEngine.evaluate(rule, m, ctx).map { (m, $0) } }
        }.value
    }

    // MARK: - Automatic cycle

    /// Called by the monitor every 2 minutes with the latest INBOX mail of each account.
    /// One clock (`now`) for the whole cycle: history, "processed" and pruning agree.
    func runCycle(fresh: [MailMessage], now: Date = Date()) async {
        guard !isRunning, hasActiveRules else { return }
        isRunning = true
        defer { isRunning = false }
        try? store.upsertNow(fresh)

        let active = rules.filter { $0.isEnabled && $0.pausedReason == nil && $0.enabledAt != nil }
        guard let earliest = active.compactMap(\.enabledAt).min() else { return }
        let since = max(earliest, now.addingTimeInterval(-Self.candidateWindow))
        let candidates = (try? store.unprocessedInbox(since: since, limit: 1_000)) ?? []
        let ctx = context()

        var planned: [(Rule, RuleMatch, MailMessage)] = []
        var unmatched: [String] = []
        for m in candidates {
            let eligible = active.filter { m.dateReceived >= ($0.enabledAt ?? .distantFuture) }
            if let hit = RuleEngine.firstMatch(eligible, m, ctx) {
                planned.append((hit.rule, hit.match, m))
            } else {
                unmatched.append(RuleEngine.stableKey(m))
            }
        }
        try? store.markProcessed(unmatched, at: now)

        let braked = RuleEngine.brakedRules(planned.map { ($0.0, $0.2) }, limit: Self.brakeLimit)
            .subtracting(bypassBrakeOnce)
        bypassBrakeOnce.removeAll()
        for id in braked {
            let n = planned.filter { $0.0.id == id }.count
            pause(id, reason: "Freno: iba a actuar sobre \(n) correos en un solo ciclo")
        }
        // Braked messages stay unprocessed: they run after "Continuar".
        await execute(planned.filter { !braked.contains($0.0.id) }, trigger: .auto, now: now)
        try? store.pruneRuleData(now: now)
    }

    // MARK: - Execution

    /// Applies the actions in Mail (grouped by rule, account and mailbox), records the
    /// history, marks messages processed and tells MailManager what changed.
    @discardableResult
    func execute(_ planned: [(Rule, RuleMatch, MailMessage)], trigger: RuleRun.Trigger,
                 now: Date = Date()) async -> [RuleRun] {
        guard !planned.isEmpty else { return [] }
        let batch = UUID().uuidString
        var runs: [RuleRun] = []
        var removed: [String] = [], read: [String] = []
        var failedRules = Set<String>(), okRules = Set<String>()

        let groups = Dictionary(grouping: planned) { "\($0.0.id)\u{1}\($0.2.account)\u{1}\($0.2.mailbox)" }
        for items in groups.values {
            let rule = items[0].0, account = items[0].2.account, mailbox = items[0].2.mailbox
            let ids = items.map { $0.2.messageId }
            var okIds = Set<Int>(), rfc: [Int: String] = [:], target: String?, failure: String?
            do {
                switch rule.action {
                case .markRead:
                    okIds = Set(try await bridge.apply(.setRead(true), ids: ids, mailbox: mailbox, account: account))
                case .flag:
                    okIds = Set(try await bridge.apply(.setFlag(true), ids: ids, mailbox: mailbox, account: account))
                case .move, .archive, .delete:
                    target = try resolveTarget(rule.action, account: account)
                    rfc = try await bridge.rfcMessageIDs(ids: ids, mailbox: mailbox, account: account)
                    let undoable = ids.filter { rfc[$0] != nil }
                    let op: MailBridge.BridgeOp = rule.action == .delete ? .delete : .move(to: target ?? "")
                    okIds = Set(try await bridge.apply(op, ids: undoable, mailbox: mailbox, account: account))
                }
            } catch {
                failure = error.localizedDescription
            }

            for (rule, match, m) in items {
                let ok = okIds.contains(m.messageId)
                let noRFC = rule.action.isDisplacing && failure == nil && rfc[m.messageId] == nil
                let why = failure ?? (noRFC ? "Sin Message-ID: no se actuó, para poder deshacer" : "Mail no aplicó la acción")
                runs.append(RuleRun(id: nil, batchId: batch, ruleId: rule.id, ruleName: rule.name,
                                    messageKey: RuleEngine.stableKey(m), account: m.account, mailbox: m.mailbox,
                                    messageId: m.messageId, rfcMessageId: rfc[m.messageId], targetMailbox: target,
                                    sender: m.senderAddress, subject: m.subject, action: rule.action.kind,
                                    reason: match.reason, trigger: trigger, status: ok ? .ok : .failed,
                                    error: ok ? nil : why, executedAt: now, undoneAt: nil))
                if ok && rule.action.isDisplacing { removed.append(m.id) }
                if ok && rule.action == .markRead { read.append(m.id) }
            }
            if okIds.count == ids.count { okRules.insert(rule.id) } else { failedRules.insert(rule.id) }
        }

        let saved = (try? store.insertRuns(runs)) ?? runs
        try? store.markProcessed(runs.map(\.messageKey), at: now)
        onApplied(removed, read)
        okRules.subtracting(failedRules).forEach(resetFailures)
        failedRules.forEach(registerFailure)
        loadHistory()
        return saved
    }

    /// Where the message goes (move/archive) or where undo will look for it (delete → Trash).
    private func resolveTarget(_ action: RuleAction, account: String) throws -> String? {
        switch action {
        case .move(_, let mailbox): return mailbox
        case .archive:
            guard let box = MailboxResolver.archive(in: mailboxesOf(account)) else {
                throw RuleRunnerError.noMailbox(kind: "Archivo", account: account)
            }
            return box
        case .delete:
            guard let box = MailboxResolver.trash(in: mailboxesOf(account)) else {
                throw RuleRunnerError.noMailbox(kind: "Papelera", account: account)
            }
            return box
        case .markRead, .flag: return nil
        }
    }

    private func registerFailure(_ id: String) {
        guard var r = rules.first(where: { $0.id == id }) else { return }
        r.consecutiveFailures += 1
        persist(r)
        if r.consecutiveFailures >= Self.failureLimit { pause(id, reason: "\(Self.failureLimit) fallos seguidos") }
    }

    private func resetFailures(_ id: String) {
        guard var r = rules.first(where: { $0.id == id }), r.consecutiveFailures > 0 else { return }
        r.consecutiveFailures = 0
        persist(r)
    }

    private func pause(_ id: String, reason: String) {
        guard var r = rules.first(where: { $0.id == id }) else { return }
        r.pausedReason = reason
        persist(r)
        notices.append(RuleNotice(ruleId: id, ruleName: r.name, message: reason))
    }

    // MARK: - Undo

    /// Undoes history rows. One row teaches the rule ("never" for that sender);
    /// a whole batch doesn't (the rule itself was probably wrong).
    func undo(runIds: [Int64]) async {
        guard let runs = try? store.runs(ids: runIds) else { return }
        var undone: [RuleRun] = []
        for run in runs where run.status == .ok {
            guard let id = run.id else { continue }
            do {
                try await undoOne(run)
                try store.setRunStatus(ids: [id], .undone)
                undone.append(run)
            } catch {
                try? store.setRunStatus(ids: [id], .undoFailed, error: error.localizedDescription)
            }
        }
        if runIds.count == 1, let run = undone.first { learnNever(from: run) }
        loadHistory()
    }

    /// History ids of a whole execution ("Deshacer ejecución").
    func runIds(ofBatch batch: String) -> [Int64] {
        history.filter { $0.batchId == batch && $0.status == .ok }.compactMap(\.id)
    }

    private func undoOne(_ run: RuleRun) async throws {
        switch run.action {
        case "move", "archive", "delete":
            // Delete: `targetMailbox` is the account's Trash, resolved when the rule ran.
            guard let rid = run.rfcMessageId, let from = run.targetMailbox else { throw UndoError.cannotLocate }
            let moved = try await bridge.moveByRFC([rid], from: from, to: run.mailbox, account: run.account)
            guard !moved.isEmpty else { throw UndoError.notFound(from) }
        case "markRead":
            let ok = try await bridge.apply(.setRead(false), ids: [run.messageId], mailbox: run.mailbox, account: run.account)
            guard !ok.isEmpty else { throw UndoError.notFound(run.mailbox) }
        case "flag":
            let ok = try await bridge.apply(.setFlag(false), ids: [run.messageId], mailbox: run.mailbox, account: run.account)
            guard !ok.isEmpty else { throw UndoError.notFound(run.mailbox) }
        default:
            throw UndoError.cannotLocate
        }
    }

    private func learnNever(from run: RuleRun) {
        guard var r = rules.first(where: { $0.id == run.ruleId }) else { return }
        let address = run.sender.lowercased()
        guard !r.neverSenders.contains(where: { $0.address.lowercased() == address }) else { return }
        r.neverSenders.append(SenderEntry(address: run.sender, origin: .correction))
        persist(r)
    }
}

enum UndoError: LocalizedError {
    case cannotLocate
    case notFound(String)
    var errorDescription: String? {
        switch self {
        case .cannotLocate: "No hay datos para localizar el correo"
        case .notFound(let box): "No está en «\(box)» (¿se vació la Papelera o se movió a mano?)"
        }
    }
}
