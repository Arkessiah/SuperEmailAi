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

    @Published var searchText: String = "" { didSet { applyFilters() } }
    @Published var selectedSender: SenderGroup? = nil
    @Published var selectedMessages: Set<String> = []

    @Published var isLoading = false
    @Published var statusMessage = "Listo"
    @Published var errorMessage: String?

    @Published var currentMailbox: String = "INBOX"
    @Published var currentAccount: String? = nil

    @Published var sortOrder: SortOrder = .countDesc

    enum SortOrder: String, CaseIterable {
        case countDesc = "Mas correos"
        case countAsc = "Menos correos"
        case nameAsc = "A-Z"
        case nameDesc = "Z-A"
        case dateDesc = "Mas reciente"
        case dateAsc = "Mas antiguo"
    }

    private let bridge = MailBridge.shared

    // MARK: - Load messages

    func loadMessages(limit: Int = 1000) async {
        isLoading = true
        statusMessage = "Cargando correos de \(currentMailbox)..."
        errorMessage = nil

        do {
            allMessages = try await bridge.fetchMessages(
                from: currentMailbox,
                account: currentAccount,
                limit: limit
            )
            buildSenderGroups()
            statusMessage = "\(allMessages.count) correos cargados"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Error al cargar"
        }

        isLoading = false
    }

    // MARK: - Accounts

    func loadAccounts() async {
        do {
            accounts = try await bridge.fetchAccounts()
                .map { MailAccount(name: $0.name, mailboxes: $0.mailboxes) }
        } catch {
            accounts = []
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

    /// Selects an account (nil = all accounts), refreshes its mailboxes and reloads.
    func selectAccount(_ account: String?) async {
        currentAccount = account
        rebuildMailboxList()
        await loadMessages()
    }

    /// Selects a mailbox and reloads its messages.
    func selectMailbox(_ mailbox: String) async {
        currentMailbox = mailbox
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

    func deleteSelectedMessages() async {
        guard !selectedMessages.isEmpty else { return }

        let toDelete = allMessages.filter { selectedMessages.contains($0.id) }

        isLoading = true
        statusMessage = "Eliminando \(toDelete.count) correos..."

        do {
            let count = try await bridgeDelete(toDelete)
            statusMessage = "\(count) correos eliminados"
            allMessages.removeAll { selectedMessages.contains($0.id) }
            selectedMessages.removeAll()
            buildSenderGroups()
            applyFilters()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Error al eliminar"
        }

        isLoading = false
    }

    func deleteMessagesFromSender(_ sender: SenderGroup) async {
        isLoading = true
        statusMessage = "Eliminando \(sender.messages.count) correos de \(sender.displayName)..."

        do {
            let count = try await bridgeDelete(sender.messages)
            statusMessage = "\(count) correos eliminados"
            let idsToRemove = Set(sender.messages.map(\.id))
            allMessages.removeAll { idsToRemove.contains($0.id) }
            buildSenderGroups()
            applyFilters()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
        guard !toDelete.isEmpty else { return }

        isLoading = true
        statusMessage = "Eliminando \(toDelete.count) duplicados..."

        do {
            let deletedTotal = try await bridgeDelete(toDelete)

            let idsToRemove = Set(toDelete.map(\.id))
            allMessages.removeAll { idsToRemove.contains($0.id) }
            buildSenderGroups()
            applyFilters()
            findDuplicates()
            statusMessage = "\(deletedTotal) duplicados eliminados"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Error al eliminar duplicados"
        }

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
    }

    func selectSender(_ sender: SenderGroup?) {
        selectedSender = sender
        selectedMessages.removeAll()
        applyFilters()
    }
}
