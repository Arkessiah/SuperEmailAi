import Foundation
import SwiftUI

@MainActor
final class MailManager: ObservableObject {

    // MARK: - Published state

    @Published var allMessages: [MailMessage] = []
    @Published var senderGroups: [SenderGroup] = []
    @Published var filteredMessages: [MailMessage] = []
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var mailboxes: [String] = []
    @Published var accounts: [MailAccount] = []
    @Published var unreadByAccount: [String: Int] = [:]   // account name -> INBOX unread
    @Published var newsletterSenders: Set<String> = []    // senders confirmed as newsletters (List-Unsubscribe)
    @Published var importantSenders: Set<String> = []     // senders scored as important (float to top)
    @Published var messageSort: MessageSort = .date { didSet { applyFilters() } }

    enum MessageSort: String, CaseIterable {
        case date = "Reciente"
        case importance = "Importancia"
        case size = "Tamaño"
    }

    @Published var searchText: String = "" { didSet { runIndexSearch() } }
    @Published var searchResults: [MailMessage]? = nil   // global FTS results (nil = not searching)
    @Published var selectedSender: SenderGroup? = nil
    @Published var selectedMessages: Set<String> = []

    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var isLoadingMore = false
    @Published var canLoadMore = true
    @Published var loadProgress: Double?     // 0...1 during a first (no-cache) load
    @Published var statusMessage = "Listo"
    @Published var backfillStatus: String?   // shown while indexing history in the background
    @Published var errorMessage: String?

    @Published var currentMailbox: String = "INBOX"
    @Published var currentAccount: String? = nil

    @Published var sortOrder: SortOrder = .countDesc

    // Reading pane
    @Published var isReadingOpen = false
    @Published var openedMessage: MailMessage?
    @Published var openedBody: String = ""
    @Published var openedHTML: String?
    @Published var openedRecipients: [String] = []
    @Published var openedUnsubscribeURL: URL?
    @Published var isLoadingBody = false
    @Published var showRemoteImages = false   // per-message opt-in to remote content

    /// App mode: a standard reader (Spark-like) vs the sender-grouping cleanup tool.
    @Published var mode: AppMode = .lectura

    enum AppMode: String, CaseIterable {
        case inicio = "Inicio"
        case lectura = "Lectura"
        case limpieza = "Limpieza"
    }

    enum SortOrder: String, CaseIterable {
        case countDesc = "Mas correos"
        case countAsc = "Menos correos"
        case nameAsc = "A-Z"
        case nameDesc = "Z-A"
        case dateDesc = "Mas reciente"
        case dateAsc = "Mas antiguo"
    }

    private let bridge = MailBridge.shared
    private let cache = MailCache.shared
    private let store = MessageStore.shared   // Phase 1: SQLite index (write in parallel)

    init() {
        newsletterSenders = Set(UserDefaults.standard.stringArray(forKey: "newsletterSenders") ?? [])
        importantSenders = Set(UserDefaults.standard.stringArray(forKey: "importantSenders") ?? [])
        loadAutoReply()
    }

    // MARK: - Alerts (incoming-mail monitor for important senders)

    @Published var alerts: [MailMessage] = []
    private var seenAlertIDs: Set<String> = []
    private var alertsTask: Task<Void, Never>?

    /// Starts polling INBOX for new mail from important senders (in-app alerts).
    func startAlertsMonitor() {
        guard alertsTask == nil else { return }
        alertsTask = Task { [weak self] in
            await self?.baselineSeenIDs()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)   // 2 min
                if Task.isCancelled { break }
                await self?.checkForAlerts()
            }
        }
    }

    private func baselineSeenIDs() async {
        for account in accounts {
            if let recent = try? await bridge.fetchMessages(from: "INBOX", account: account.name, limit: 30) {
                for m in recent { seenAlertIDs.insert(m.id) }
            }
        }
    }

    private func checkForAlerts() async {
        guard !importantSenders.isEmpty || autoReplyEnabled else { return }
        for account in accounts {
            guard let recent = try? await bridge.fetchMessages(from: "INBOX", account: account.name, limit: 15) else { continue }
            for m in recent where !seenAlertIDs.contains(m.id) {
                seenAlertIDs.insert(m.id)
                if importantSenders.contains(m.senderAddress) {
                    alerts.insert(m, at: 0)
                }
                await maybeAutoReply(to: m)
            }
        }
        if alerts.count > 50 { alerts = Array(alerts.prefix(50)) }
    }

    func dismissAlert(_ id: String) { alerts.removeAll { $0.id == id } }
    func clearAlerts() { alerts.removeAll() }

    // MARK: - Auto-reply (out-of-office)

    enum AutoReplyScope: String, CaseIterable {
        case importantOnly = "Solo importantes"
        case all = "A todos"
    }

    @Published var autoReplyEnabled = false {
        didSet { UserDefaults.standard.set(autoReplyEnabled, forKey: "autoReplyEnabled") }
    }
    @Published var autoReplyMessage = "" {
        didSet { UserDefaults.standard.set(autoReplyMessage, forKey: "autoReplyMessage") }
    }
    @Published var autoReplyScopeRaw = AutoReplyScope.importantOnly.rawValue {
        didSet { UserDefaults.standard.set(autoReplyScopeRaw, forKey: "autoReplyScope") }
    }
    @Published var autoReplyCount = 0
    private var repliedSenders: Set<String> = []

    var autoReplyScope: AutoReplyScope { AutoReplyScope(rawValue: autoReplyScopeRaw) ?? .importantOnly }

    private func loadAutoReply() {
        autoReplyEnabled = UserDefaults.standard.bool(forKey: "autoReplyEnabled")
        autoReplyMessage = UserDefaults.standard.string(forKey: "autoReplyMessage") ?? ""
        autoReplyScopeRaw = UserDefaults.standard.string(forKey: "autoReplyScope") ?? AutoReplyScope.importantOnly.rawValue
        repliedSenders = Set(UserDefaults.standard.stringArray(forKey: "repliedSenders") ?? [])
        autoReplyCount = repliedSenders.count
    }

    func resetRepliedSenders() {
        repliedSenders = []
        autoReplyCount = 0
        UserDefaults.standard.removeObject(forKey: "repliedSenders")
    }

    /// Sends the auto-reply for a newly-arrived message if it qualifies. Safe by
    /// design: only to real people (.personas), once per sender, never to
    /// notifications / newsletters / no-reply.
    private func maybeAutoReply(to message: MailMessage) async {
        guard autoReplyEnabled,
              !autoReplyMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !message.senderAddress.isEmpty,
              !message.account.isEmpty,
              !repliedSenders.contains(message.senderAddress),
              category(for: message) == .personas
        else { return }

        guard autoReplyScope == .all || importantSenders.contains(message.senderAddress) else { return }

        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        do {
            try await bridge.sendMail(to: message.senderAddress, subject: subject, body: autoReplyMessage, fromAccount: message.account)
            repliedSenders.insert(message.senderAddress)
            autoReplyCount = repliedSenders.count
            UserDefaults.standard.set(Array(repliedSenders), forKey: "repliedSenders")
        } catch {
            // Silent; the next poll will retry.
        }
    }

    /// Toggles a sender's "important" score (used by the sort-by-importance view).
    func toggleImportant(_ senderAddress: String) {
        guard !senderAddress.isEmpty else { return }
        if importantSenders.contains(senderAddress) {
            importantSenders.remove(senderAddress)
        } else {
            importantSenders.insert(senderAddress)
        }
        UserDefaults.standard.set(Array(importantSenders), forKey: "importantSenders")
        applyFilters()
    }

    /// Smart-Inbox category for a message, refined by senders we've confirmed are
    /// newsletters (via List-Unsubscribe) on top of the sender heuristic.
    func category(for message: MailMessage) -> MailCategory {
        if newsletterSenders.contains(message.senderAddress) { return .boletines }
        return message.category
    }

    private func rememberNewsletter(_ senderAddress: String) {
        guard !senderAddress.isEmpty, !newsletterSenders.contains(senderAddress) else { return }
        newsletterSenders.insert(senderAddress)
        UserDefaults.standard.set(Array(newsletterSenders), forKey: "newsletterSenders")
    }

    // MARK: - Load messages

    /// Populates the UI from the cache synchronously (instant, no Mail.app round-trip).
    /// Used on launch so the last messages show immediately before refreshing.
    func showCachedInstantly() {
        if !cache.accounts.isEmpty {
            accounts = cache.accounts
            rebuildMailboxList()
        }
        if let cached = cache.messages(account: currentAccount, mailbox: currentMailbox), !cached.isEmpty {
            allMessages = cached
            buildSenderGroups()
            applyFilters()
            statusMessage = "\(cached.count) en caché · actualizando…"
        }
    }

    /// Cache-first load: shows cached messages instantly (if any), then refreshes
    /// from Mail.app. When there is no cache it shows a progress overlay and
    /// streams messages account-by-account so they appear as they arrive.
    func loadMessages(limit: Int = 1000) async {
        errorMessage = nil
        canLoadMore = true

        // Instant display from the SQLite index (falls back to the JSON cache).
        let indexed = store.recent(account: currentAccount, mailbox: currentMailbox, limit: 1000)
        let cached = indexed.isEmpty
            ? (cache.messages(account: currentAccount, mailbox: currentMailbox) ?? [])
            : indexed
        if !cached.isEmpty {
            allMessages = cached
            buildSenderGroups()
            applyFilters()
            statusMessage = "\(cached.count) en índice · actualizando…"
            isRefreshing = true
            isLoading = false
            await refresh(limit: limit, withProgress: false)
        } else {
            isLoading = true
            loadProgress = 0
            statusMessage = "Cargando correos…"
            await refresh(limit: limit, withProgress: true)
        }

        isLoading = false
        isRefreshing = false
        loadProgress = nil
    }

    /// Fetches the current view. For "all accounts" it streams account-by-account
    /// so messages appear progressively and `loadProgress` reflects real progress.
    private func refresh(limit: Int, withProgress: Bool) async {
        if let account = currentAccount {
            if let fresh = try? await bridge.fetchMessages(from: currentMailbox, account: account, limit: limit) {
                if currentMailbox == "INBOX" {
                    unreadByAccount[account] = fresh.filter { !$0.isRead }.count
                }
                if withProgress { allMessages = fresh } else { mergeFresh(fresh) }
                buildSenderGroups()
                applyFilters()
                cache.update(allMessages, account: account, mailbox: currentMailbox)
                store.upsert(fresh)
                statusMessage = "\(allMessages.count) correos"
            } else if allMessages.isEmpty {
                statusMessage = "Error al cargar"
            }
            if withProgress { loadProgress = 1 }
            return
        }

        let targets = accounts
        guard !targets.isEmpty else { return }
        let perAccount = 120
        var collected: [MailMessage] = []
        for (index, account) in targets.enumerated() {
            if let fresh = try? await bridge.fetchMessages(from: currentMailbox, account: account.name, limit: perAccount) {
                collected.append(contentsOf: fresh)
                store.upsert(fresh)
                if currentMailbox == "INBOX" {
                    unreadByAccount[account.name] = fresh.filter { !$0.isRead }.count
                }
                // Only stream into the visible list when nothing is shown yet
                // (no index/cache). Otherwise we merge once at the end to avoid
                // the list collapsing and reordering ("things load and change").
                if withProgress {
                    allMessages = collected
                    buildSenderGroups()
                    applyFilters()
                }
            }
            if withProgress {
                loadProgress = Double(index + 1) / Double(targets.count)
                statusMessage = "Cargando… \(collected.count) correos"
            }
        }
        if withProgress { allMessages = collected } else { mergeFresh(collected) }
        buildSenderGroups()
        applyFilters()
        cache.update(allMessages, account: nil, mailbox: currentMailbox)
        statusMessage = "\(allMessages.count) correos"
    }

    /// Merges freshly-fetched messages into `allMessages` without collapsing the
    /// list: updates existing entries in place (read status, size) and appends
    /// genuinely new ones, preserving order. Prevents the refresh flicker.
    private func mergeFresh(_ fresh: [MailMessage]) {
        guard !fresh.isEmpty else { return }
        let freshByID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let existingIDs = Set(allMessages.map(\.id))
        allMessages = allMessages.map { freshByID[$0.id] ?? $0 }
        allMessages.append(contentsOf: fresh.filter { !existingIDs.contains($0.id) })
    }

    /// Loads the next page of (older) messages and appends them — drives the
    /// infinite scroll. The per-account offset is derived from how many of each
    /// account's messages are already loaded.
    func loadMoreMessages(pageSize: Int = 100) async {
        guard !isLoadingMore, canLoadMore, !isLoading else { return }
        isLoadingMore = true

        let accountNames: [String] = currentAccount.map { [$0] } ?? accounts.map(\.name)
        let existing = Set(allMessages.map(\.id))
        var newMessages: [MailMessage] = []

        for accName in accountNames {
            let alreadyLoaded = allMessages.lazy.filter { $0.account == accName }.count
            if let more = try? await bridge.fetchMessagesRange(
                mailbox: currentMailbox, account: accName, offset: alreadyLoaded, limit: pageSize
            ) {
                newMessages.append(contentsOf: more.filter { !existing.contains($0.id) })
            }
        }

        if newMessages.isEmpty {
            canLoadMore = false
        } else {
            allMessages.append(contentsOf: newMessages)
            buildSenderGroups()
            applyFilters()
            cache.update(allMessages, account: currentAccount, mailbox: currentMailbox)
            store.upsert(newMessages)
            statusMessage = "\(allMessages.count) correos"
        }

        isLoadingMore = false
    }

    // MARK: - Reading a message

    /// Opens the reading pane (right column) for a message and loads its body.
    func openForReading(_ message: MailMessage) async {
        isReadingOpen = true
        await openMessage(message)
    }

    /// Closes the reading pane.
    func closeReading() {
        isReadingOpen = false
        openedMessage = nil
    }

    /// Loads the body of a message into the reading pane (HTML if available,
    /// otherwise plain text).
    func openMessage(_ message: MailMessage) async {
        openedMessage = message
        openedBody = ""
        openedHTML = nil
        openedRecipients = []
        openedUnsubscribeURL = nil
        showRemoteImages = false
        isLoadingBody = true
        do {
            let account = message.account.isEmpty ? nil : message.account
            let raw = try await bridge.fetchMessageRaw(
                id: message.messageId,
                mailbox: message.mailbox,
                account: account
            )
            openedBody = raw.content
            openedRecipients = raw.recipients.isEmpty ? MIMEParser.recipients(fromSource: raw.source) : raw.recipients
            openedHTML = MIMEParser.htmlBody(fromSource: raw.source)
            openedUnsubscribeURL = MIMEParser.listUnsubscribe(fromSource: raw.source).https
            if openedUnsubscribeURL != nil {
                rememberNewsletter(message.senderAddress)
            }
        } catch {
            openedBody = "(No se pudo cargar el contenido: \(error.localizedDescription))"
        }
        isLoadingBody = false

        // Mark as read on open (Spark behavior).
        if !message.isRead {
            let account = message.account.isEmpty ? nil : message.account
            _ = try? await bridge.setReadStatus(ids: [message.messageId], read: true, mailbox: message.mailbox, account: account)
            if let index = allMessages.firstIndex(where: { $0.id == message.id }) {
                allMessages[index] = allMessages[index].with(isRead: true)
                buildSenderGroups()
                applyFilters()
                cache.update(allMessages, account: currentAccount, mailbox: currentMailbox)
            }
        }
    }

    // MARK: - Accounts

    func loadAccounts() async {
        if accounts.isEmpty, !cache.accounts.isEmpty {
            accounts = cache.accounts
            rebuildMailboxList()
        }
        do {
            let fresh = try await bridge.fetchAccounts()
                .map { MailAccount(name: $0.name, mailboxes: $0.mailboxes) }
            accounts = fresh
            cache.setAccounts(fresh)
        } catch {
            // Keep cached/previous accounts on failure.
        }
        rebuildMailboxList()
    }

    /// Rebuilds `mailboxes` for the current account selection: a single account's
    /// mailboxes, or the deduplicated union across all accounts ("Todas").
    private func rebuildMailboxList() {
        if let account = currentAccount, let match = accounts.first(where: { $0.name == account }) {
            mailboxes = match.mailboxes
        } else if !accounts.isEmpty {
            var seen = Set<String>()
            mailboxes = accounts.flatMap(\.mailboxes).filter { seen.insert($0).inserted }
        } else {
            mailboxes = ["INBOX", "Sent Messages", "Drafts", "Trash", "Junk"]
        }

        // Keep the current mailbox valid for the new list.
        if !mailboxes.contains(currentMailbox) {
            currentMailbox = mailboxes.contains("INBOX") ? "INBOX" : (mailboxes.first ?? "INBOX")
        }
    }

    /// Background warm-up: fetches the most recent INBOX messages of each account
    /// into the cache, so selecting an account is instant on future visits. Kept
    /// light (one mailbox per account) to avoid hammering Mail; silent and
    /// cancellable.
    func prefetchAllMailboxes(perMailbox: Int = 50) async {
        let mailbox = "INBOX"
        for account in accounts {
            if Task.isCancelled { return }
            if account.name == currentAccount && mailbox == currentMailbox { continue }
            if let fresh = try? await bridge.fetchMessages(from: mailbox, account: account.name, limit: perMailbox) {
                cache.update(fresh, account: account.name, mailbox: mailbox)
                store.upsert(fresh)
                unreadByAccount[account.name] = fresh.filter { !$0.isRead }.count
            }
        }
    }

    // MARK: - Historical backfill (Phase 4)

    private var backfillTask: Task<Void, Never>?

    /// Indexes ALL historical mail (oldest beyond the loaded window) in the
    /// background, page by page, so search/load eventually cover everything.
    /// Resumes from a persisted cursor per account; gentle on Mail.app.
    func startBackfill() {
        guard backfillTask == nil else { return }
        backfillTask = Task { [weak self] in await self?.runBackfill() }
    }

    private func runBackfill(mailbox: String = "INBOX", pageSize: Int = 200) async {
        let targets = currentAccount.map { name in accounts.filter { $0.name == name } } ?? accounts
        for account in targets {
            var (offset, done) = store.backfillCursor(account: account.name, mailbox: mailbox)
            if done { continue }
            var emptyRetries = 0
            while !Task.isCancelled {
                let page = (try? await bridge.fetchMessagesRange(
                    mailbox: mailbox, account: account.name, offset: offset, limit: pageSize
                )) ?? []
                if page.isEmpty {
                    // Could be a transient AppleScript hiccup rather than the real
                    // end — retry once before declaring this account done.
                    if emptyRetries < 1 {
                        emptyRetries += 1
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        continue
                    }
                    store.setBackfillCursor(account: account.name, mailbox: mailbox, offset: offset, done: true)
                    break
                }
                emptyRetries = 0
                store.upsert(page)
                offset += page.count
                let reachedEnd = page.count < pageSize
                store.setBackfillCursor(account: account.name, mailbox: mailbox, offset: offset, done: reachedEnd)
                backfillStatus = "Indexando histórico… \(store.count()) en índice"
                if reachedEnd { break }
                try? await Task.sleep(nanoseconds: 400_000_000)   // 0.4s gentle pause
            }
            if Task.isCancelled { break }
        }
        backfillStatus = nil
        backfillTask = nil
    }

    /// Selects an account (nil = all accounts), refreshes its mailboxes and reloads.
    func selectAccount(_ account: String?) async {
        closeReading()
        currentAccount = account
        rebuildMailboxList()
        await loadMessages()
    }

    /// Selects a mailbox and reloads its messages.
    func selectMailbox(_ mailbox: String) async {
        closeReading()
        currentMailbox = mailbox
        await loadMessages()
    }

    /// Opens a specific account+mailbox (used by the reader's folder sidebar).
    func openMailbox(account: String?, mailbox: String) async {
        closeReading()
        currentAccount = account
        currentMailbox = mailbox
        selectedSender = nil
        rebuildMailboxList()
        await loadMessages()
    }

    // MARK: - Search by sender

    func searchBySender(_ address: String) async {
        isLoading = true
        statusMessage = "Buscando correos de \(address)..."

        do {
            let results = try await bridge.searchBySender(
                address: address,
                mailbox: currentMailbox,
                account: currentAccount
            )
            filteredMessages = results
            statusMessage = "\(results.count) correos de \(address)"
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Bridge helpers (group by real account + mailbox)

    private static let targetSeparator = "\u{0001}"

    /// Deletes the given messages, grouping them by their real account + mailbox
    /// so each delete is correctly qualified `of account`.
    private func bridgeDelete(_ messages: [MailMessage]) async throws -> Int {
        let groups = Dictionary(grouping: messages) { "\($0.account)\(Self.targetSeparator)\($0.mailbox)" }
        var total = 0
        for (key, msgs) in groups {
            let parts = key.components(separatedBy: Self.targetSeparator)
            let account = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            let mailbox = parts.count > 1 ? parts[1] : currentMailbox
            total += try await bridge.deleteMessages(ids: msgs.map(\.messageId), mailbox: mailbox, account: account)
        }
        return total
    }

    /// Moves the given messages to `targetMailbox`, grouping by their real
    /// account + mailbox. The target is resolved within each source account.
    private func bridgeMove(_ messages: [MailMessage], to targetMailbox: String) async throws -> Int {
        let groups = Dictionary(grouping: messages) { "\($0.account)\(Self.targetSeparator)\($0.mailbox)" }
        var total = 0
        for (key, msgs) in groups {
            let parts = key.components(separatedBy: Self.targetSeparator)
            let account = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            let mailbox = parts.count > 1 ? parts[1] : currentMailbox
            total += try await bridge.moveMessages(ids: msgs.map(\.messageId), fromMailbox: mailbox, toMailbox: targetMailbox, account: account)
        }
        return total
    }

    // MARK: - Delete messages

    /// Optimistic delete: removes the messages from the UI immediately, then
    /// deletes them in Mail in the background. On failure it reloads to resync
    /// with Mail's real state (the actual deletion may be slow over IMAP).
    private func optimisticDelete(_ messages: [MailMessage], noun: String) async {
        guard !messages.isEmpty else { return }

        let removedIds = Set(messages.map(\.id))
        allMessages.removeAll { removedIds.contains($0.id) }
        selectedMessages.subtract(removedIds)
        buildSenderGroups()
        applyFilters()
        findDuplicates()
        cache.update(allMessages, account: currentAccount, mailbox: currentMailbox)
        statusMessage = "Eliminando \(messages.count) \(noun) en segundo plano..."

        do {
            let count = try await bridgeDelete(messages)
            statusMessage = "\(count) \(noun) eliminados"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Error al eliminar — recargando..."
            await loadMessages()
        }
    }

    func deleteSelectedMessages() async {
        guard !selectedMessages.isEmpty else { return }
        let toDelete = allMessages.filter { selectedMessages.contains($0.id) }
        await optimisticDelete(toDelete, noun: "correos")
    }

    func deleteMessagesFromSender(_ sender: SenderGroup) async {
        await optimisticDelete(sender.messages, noun: "correos")
    }

    // MARK: - Move messages

    func moveSelectedMessages(to targetMailbox: String) async {
        guard !selectedMessages.isEmpty else { return }

        let toMove = allMessages.filter { selectedMessages.contains($0.id) }

        isLoading = true
        statusMessage = "Moviendo \(toMove.count) correos a \(targetMailbox)..."

        do {
            let count = try await bridgeMove(toMove, to: targetMailbox)
            statusMessage = "\(count) correos movidos a \(targetMailbox)"
            allMessages.removeAll { selectedMessages.contains($0.id) }
            selectedMessages.removeAll()
            buildSenderGroups()
            applyFilters()
            cache.update(allMessages, account: currentAccount, mailbox: currentMailbox)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func moveMessagesFromSender(_ sender: SenderGroup, to targetMailbox: String) async {
        isLoading = true
        statusMessage = "Moviendo \(sender.messages.count) correos de \(sender.displayName) a \(targetMailbox)..."

        do {
            let count = try await bridgeMove(sender.messages, to: targetMailbox)
            statusMessage = "\(count) correos movidos"
            let idsToRemove = Set(sender.messages.map(\.id))
            allMessages.removeAll { idsToRemove.contains($0.id) }
            buildSenderGroups()
            applyFilters()
            cache.update(allMessages, account: currentAccount, mailbox: currentMailbox)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Duplicate detection

    func findDuplicates() {
        let grouped = Dictionary(grouping: allMessages) { msg in
            "\(msg.senderAddress)|\(msg.subject.lowercased().trimmingCharacters(in: .whitespaces))"
        }

        duplicateGroups = grouped
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(subject: $0.value.first?.subject ?? "", sender: $0.value.first?.senderAddress ?? "", messages: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// Deletes the extra copies of a duplicate group, keeping the first one.
    /// Routes through the bridge here (not from the view) and groups messages by
    /// account + mailbox, since duplicates can live in different mailboxes.
    func deleteDuplicateExtras(_ group: DuplicateGroup) async {
        let toDelete = Array(group.messages.dropFirst())
        await optimisticDelete(toDelete, noun: "duplicados")
    }

    // MARK: - Triage actions (keyboard)

    /// Toggles read state for the current selection (if any is unread → mark all
    /// read; else mark all unread).
    func toggleReadForSelection() async {
        let selected = allMessages.filter { selectedMessages.contains($0.id) }
        guard !selected.isEmpty else { return }
        let markRead = selected.contains { !$0.isRead }

        let separator = "\u{0001}"
        let groups = Dictionary(grouping: selected) { "\($0.account)\(separator)\($0.mailbox)" }
        for (key, msgs) in groups {
            let parts = key.components(separatedBy: separator)
            let account = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            let mailbox = parts.count > 1 ? parts[1] : currentMailbox
            _ = try? await bridge.setReadStatus(ids: msgs.map(\.messageId), read: markRead, mailbox: mailbox, account: account)
        }

        let ids = Set(selected.map(\.id))
        allMessages = allMessages.map { ids.contains($0.id) ? $0.with(isRead: markRead) : $0 }
        buildSenderGroups()
        applyFilters()
        cache.update(allMessages, account: currentAccount, mailbox: currentMailbox)
        statusMessage = markRead ? "Marcados como leídos" : "Marcados como no leídos"
    }

    /// Archives the current selection (moves to the "Archive" mailbox).
    func archiveSelection() async {
        await moveSelectedMessages(to: "Archive")
    }

    /// Opens the open message's unsubscribe link in the browser.
    func unsubscribeFromOpened() {
        guard let url = openedUnsubscribeURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Deletes every message from the open message's sender in its mailbox.
    func deleteAllFromOpenedSender() async {
        guard let msg = openedMessage, !msg.senderAddress.isEmpty,
              !msg.account.isEmpty else { return }
        isLoading = true
        statusMessage = "Eliminando todos los correos de \(msg.senderAddress)…"
        let predicate = "sender contains \"\(escapeForAppleScript(msg.senderAddress))\""
        let total = (try? await bridge.bulkDelete(mailbox: msg.mailbox, account: msg.account, predicate: predicate)) ?? 0
        allMessages.removeAll { $0.senderAddress == msg.senderAddress }
        buildSenderGroups()
        applyFilters()
        cache.update(allMessages, account: currentAccount, mailbox: currentMailbox)
        statusMessage = "\(total) correos de \(msg.senderAddress) eliminados"
        closeReading()
        isLoading = false
    }

    // MARK: - Ask AI (rule-based natural-language cleanup, v1)

    struct AIIntent {
        var senderContains = ""
        var olderThanDays: Int?
        var unreadOnly = false
        var readOnly = false

        var isEmpty: Bool {
            senderContains.isEmpty && olderThanDays == nil && !unreadOnly && !readOnly
        }

        /// Human-readable interpretation for the preview.
        var summary: String {
            var parts: [String] = []
            if !senderContains.isEmpty { parts.append("de “\(senderContains)”") }
            if let days = olderThanDays { parts.append("de más de \(days) días") }
            if unreadOnly { parts.append("no leídos") }
            if readOnly { parts.append("leídos") }
            return parts.isEmpty ? "—" : parts.joined(separator: ", ")
        }
    }

    /// Parses a free-text instruction into a cleanup intent (Spanish + English).
    func parseAICommand(_ raw: String) -> AIIntent {
        let text = raw.lowercased()
        var intent = AIIntent()

        let tokens = raw.components(separatedBy: CharacterSet(charactersIn: " \t\n,;\"'()"))
        for token in tokens where token.contains("@") {
            intent.senderContains = token.hasPrefix("@") ? String(token.dropFirst()) : token
            break
        }
        if intent.senderContains.isEmpty {
            let tlds = [".com", ".es", ".io", ".org", ".net", ".xyz", ".co", ".tech", ".dev", ".app", ".info", ".eu"]
            for token in tokens where tlds.contains(where: { token.lowercased().contains($0) }) {
                intent.senderContains = token
                break
            }
        }

        intent.olderThanDays = parseAge(from: text)

        let unreadCues = ["no leído", "no leido", "no abierto", "sin leer", "sin abrir", "unread", "not read"]
        let readCues = ["leídos", "leidos", "ya leídos", "abiertos", "ya abiertos", " read"]
        if unreadCues.contains(where: text.contains) {
            intent.unreadOnly = true
        } else if readCues.contains(where: text.contains) {
            intent.readOnly = true
        }

        return intent
    }

    private func parseAge(from text: String) -> Int? {
        let normalized = text.replacingOccurrences(of: "ñ", with: "n")
        let words = normalized.components(separatedBy: CharacterSet(charactersIn: " \t\n,;"))
        func unitDays(_ w: String) -> Int? {
            if w.hasPrefix("dia") || w.hasPrefix("day") { return 1 }
            if w.hasPrefix("semana") || w.hasPrefix("week") { return 7 }
            if w.hasPrefix("mes") || w.hasPrefix("month") { return 30 }
            if w.hasPrefix("ano") || w.hasPrefix("year") { return 365 }
            return nil
        }
        let ones = ["un", "una", "ultimo", "ultima", "el", "del", "last", "one", "a"]
        for (i, word) in words.enumerated() {
            guard let unit = unitDays(word) else { continue }
            if i > 0, let n = Int(words[i - 1]) { return n * unit }
            if i > 0, ones.contains(words[i - 1]) { return unit }
            return unit
        }
        return nil
    }

    private func aiPredicate(_ intent: AIIntent) -> String {
        var parts: [String] = []
        let sender = intent.senderContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sender.isEmpty { parts.append("sender contains \"\(escapeForAppleScript(sender))\"") }
        if let days = intent.olderThanDays { parts.append("date received < ((current date) - (\(days) * days))") }
        if intent.unreadOnly { parts.append("read status is false") }
        if intent.readOnly { parts.append("read status is true") }
        return parts.joined(separator: " and ")
    }

    func aiCount(_ intent: AIIntent) async -> Int {
        guard !intent.isEmpty else { return 0 }
        let pred = aiPredicate(intent)
        var total = 0
        for account in cleanupAccountNames() {
            if let n = try? await bridge.bulkCount(mailbox: currentMailbox, account: account, predicate: pred), n > 0 {
                total += n
            }
        }
        return total
    }

    func aiExecute(_ intent: AIIntent) async {
        guard !intent.isEmpty else { return }
        let pred = aiPredicate(intent)
        isLoading = true
        statusMessage = "Aplicando instrucción…"
        var total = 0
        for account in cleanupAccountNames() {
            if let n = try? await bridge.bulkDelete(mailbox: currentMailbox, account: account, predicate: pred) {
                total += n
            }
        }
        allMessages = []
        buildSenderGroups()
        applyFilters()
        await refresh(limit: 1000, withProgress: false)
        statusMessage = "\(total) correos movidos a la Papelera"
        isLoading = false
    }

    // MARK: - Bulk cleanup ("Llévame a cero")

    struct CleanupCriteria {
        var senderContains: String = ""   // sender / domain / brand match
        var olderThanDays: Int? = nil
        var keepUnread = true
        var keepFlagged = true
    }

    private func predicate(for c: CleanupCriteria) -> String {
        var parts: [String] = []
        let sender = c.senderContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sender.isEmpty {
            parts.append("sender contains \"\(escapeForAppleScript(sender))\"")
        }
        if let days = c.olderThanDays {
            parts.append("date received < ((current date) - (\(days) * days))")
        }
        if c.keepUnread { parts.append("read status is true") }
        if c.keepFlagged { parts.append("flagged status is false") }
        return parts.joined(separator: " and ")
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func cleanupAccountNames() -> [String] {
        currentAccount.map { [$0] } ?? accounts.map(\.name)
    }

    /// Counts how many messages the cleanup would move to Trash from the current
    /// mailbox (across the current account, or all accounts when none selected).
    func cleanupCount(_ criteria: CleanupCriteria) async -> Int {
        let pred = predicate(for: criteria)
        var total = 0
        for account in cleanupAccountNames() {
            if let n = try? await bridge.bulkCount(mailbox: currentMailbox, account: account, predicate: pred), n > 0 {
                total += n
            }
        }
        return total
    }

    /// Executes the cleanup (moves matching messages to Trash) and reloads.
    func performCleanup(_ criteria: CleanupCriteria) async {
        let pred = predicate(for: criteria)
        isLoading = true
        statusMessage = "Vaciando…"

        var total = 0
        for account in cleanupAccountNames() {
            if let n = try? await bridge.bulkDelete(mailbox: currentMailbox, account: account, predicate: pred) {
                total += n
            }
        }

        allMessages = []
        buildSenderGroups()
        applyFilters()
        await refresh(limit: 1000, withProgress: false)
        statusMessage = "\(total) correos movidos a la Papelera"
        isLoading = false
    }

    // MARK: - Selection

    func selectAll() {
        selectedMessages = Set(filteredMessages.map(\.id))
    }

    func deselectAll() {
        selectedMessages.removeAll()
    }

    func toggleSelection(_ message: MailMessage) {
        if selectedMessages.contains(message.id) {
            selectedMessages.remove(message.id)
        } else {
            selectedMessages.insert(message.id)
        }
    }

    // MARK: - Private

    private func buildSenderGroups() {
        let grouped = Dictionary(grouping: allMessages, by: \.senderAddress)

        senderGroups = grouped.map { address, messages in
            SenderGroup(
                id: address,
                address: address,
                displayName: messages.first?.sender ?? address,
                domain: messages.first?.senderDomain ?? "",
                messages: messages
            )
        }

        applySortOrder()

        // Keep the selected sender pointing at the freshly rebuilt group so the
        // detail list reflects deletes/moves (becomes nil if it has no messages left).
        if let current = selectedSender {
            selectedSender = senderGroups.first { $0.id == current.id }
        }
    }

    func applySortOrder() {
        switch sortOrder {
        case .countDesc:
            senderGroups.sort { $0.count > $1.count }
        case .countAsc:
            senderGroups.sort { $0.count < $1.count }
        case .nameAsc:
            senderGroups.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .nameDesc:
            senderGroups.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        case .dateDesc:
            senderGroups.sort { $0.latestDate > $1.latestDate }
        case .dateAsc:
            senderGroups.sort { $0.latestDate < $1.latestDate }
        }
    }

    /// Global full-text search over the SQLite index (FTS5). Empty query exits search.
    func runIndexSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = q.isEmpty ? nil : store.search(query: q, limit: 1000)
    }

    private func applyFilters() {
        if let sender = selectedSender {
            filteredMessages = sender.messages
        } else {
            filteredMessages = allMessages
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            filteredMessages = filteredMessages.filter {
                $0.senderAddress.lowercased().contains(query) ||
                $0.sender.lowercased().contains(query) ||
                $0.subject.lowercased().contains(query) ||
                $0.senderDomain.lowercased().contains(query)
            }
        }

        switch messageSort {
        case .date:
            filteredMessages.sort { $0.dateReceived > $1.dateReceived }
        case .importance:
            filteredMessages.sort { a, b in
                let ia = importantSenders.contains(a.senderAddress)
                let ib = importantSenders.contains(b.senderAddress)
                if ia != ib { return ia }
                return a.dateReceived > b.dateReceived
            }
        case .size:
            filteredMessages.sort { $0.size > $1.size }
        }
    }

    func selectSender(_ sender: SenderGroup?) {
        closeReading()
        selectedSender = sender
        selectedMessages.removeAll()
        applyFilters()
    }
}
