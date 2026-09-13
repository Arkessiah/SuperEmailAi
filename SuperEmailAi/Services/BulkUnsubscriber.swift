import Foundation

/// What happened with one sender in a bulk unsubscribe ("Boletines", ARK-203).
enum BulkOutcome: Equatable {
    case unsubscribed           // one-click POST answered 2xx
    case manualLink(URL)        // the user opens it in the browser
    case manualMail(String)     // the user sends the prepared mail
    case noOption               // the sender offers no way to unsubscribe
    case failed(String)
}

enum CleanupMode: String, CaseIterable, Identifiable {
    case none = "No tocar su bandeja"
    case archive = "Archivar su bandeja"
    case delete = "Borrar su bandeja"
    var id: String { rawValue }
}

struct BulkResult: Equatable {
    var outcomes: [String: BulkOutcome] = [:]   // by sender address
    var cleaned = 0
    var cleanupFailures: [String] = []
}

/// One-click unsubscribe (lets tests use a fake).
protocol OneClickUnsubscribing {
    func oneClick(_ url: URL) async throws
}

extension Unsubscriber: OneClickUnsubscribing {}

/// Unsubscribes from several senders at once and, optionally, archives or deletes what
/// they still have in INBOX. Only the user's click starts it; one-click where possible,
/// the rest is left for the user (a link to open or a mail to send).
@MainActor
final class BulkUnsubscriber {
    private let store: MessageStore
    private let mail: MailActions
    private let unsubscriber: OneClickUnsubscribing
    private let mailboxesOf: (String) -> [String]
    private let onApplied: (_ removedIds: [String], _ readIds: [String]) -> Void

    init(store: MessageStore = .shared, mail: MailActions = MailBridge.shared,
         unsubscriber: OneClickUnsubscribing = Unsubscriber(),
         mailboxesOf: @escaping (String) -> [String],
         onApplied: @escaping ([String], [String]) -> Void) {
        self.store = store
        self.mail = mail
        self.unsubscriber = unsubscriber
        self.mailboxesOf = mailboxesOf
        self.onApplied = onApplied
    }

    /// How a sender lets you unsubscribe: remembered, or read from its latest message's
    /// headers (and remembered). Nil when the headers can't be read.
    func options(for sender: String) async -> MIMEParser.UnsubscribeOptions? {
        if let cached = try? store.unsubscribeCache()[sender] { return cached.options }
        guard let latest = try? store.latestMessage(from: sender),
              let headers = try? await mail.fetchHeaders(id: latest.messageId, mailbox: latest.mailbox,
                                                         account: latest.account)
        else { return nil }
        let options = MIMEParser.unsubscribeOptions(fromSource: headers)
        try? store.saveUnsubscribeOptions(options, for: sender)
        return options
    }

    func run(senders: [String], cleanup: CleanupMode) async -> BulkResult {
        var result = BulkResult()
        for sender in senders {
            result.outcomes[sender] = await unsubscribe(sender)
        }
        if cleanup != .none {
            let (cleaned, failures) = await clean(senders, mode: cleanup)
            result.cleaned = cleaned
            result.cleanupFailures = failures
        }
        return result
    }

    private func unsubscribe(_ sender: String) async -> BulkOutcome {
        guard let options = await options(for: sender) else {
            return .failed("No se pudieron leer las cabeceras de su último correo")
        }
        if options.oneClick, let link = options.link {
            do {
                try await unsubscriber.oneClick(link)
                try? store.markUnsubscribed(sender)
                return .unsubscribed
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        if let link = options.link { return .manualLink(link) }
        if let mailto = options.mailto { return .manualMail(mailto) }
        return .noOption
    }

    /// Archives or deletes the senders' indexed INBOX mail, by id (never "sender contains").
    private func clean(_ senders: [String], mode: CleanupMode) async -> (Int, [String]) {
        let messages = senders.flatMap { (try? store.inboxMessages(from: $0)) ?? [] }
        let byAccount = Dictionary(grouping: messages, by: \.account)
        var targets: [String: String] = [:]
        var failures: [String] = []
        if mode == .archive {
            let plan = MailboxResolver.archiveTargets(for: Set(byAccount.keys), mailboxesOf: mailboxesOf)
            targets = plan.targets
            failures += plan.missing.map { "Sin buzón de archivo en \($0)" }
        }

        var cleaned: [MailMessage] = []
        for (account, msgs) in byAccount {
            let op: MailBridge.BridgeOp
            switch mode {
            case .delete: op = .delete
            case .archive:
                guard let target = targets[account] else { continue }
                op = .move(to: target)
            case .none: continue
            }
            do {
                let ok = Set(try await mail.apply(op, ids: msgs.map(\.messageId), mailbox: "INBOX", account: account))
                cleaned += msgs.filter { ok.contains($0.messageId) }
            } catch {
                failures.append("\(account): \(error.localizedDescription)")
            }
        }
        onApplied(cleaned.map(\.id), [])
        return (cleaned.count, failures)
    }
}
