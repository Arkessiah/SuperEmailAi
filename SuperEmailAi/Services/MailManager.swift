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

    func loadMailboxes() async {
        do {
            mailboxes = try await bridge.fetchMailboxNames()
        } catch {
            mailboxes = ["INBOX", "Sent Messages", "Drafts", "Trash", "Junk"]
        }
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

    // MARK: - Delete messages

    func deleteSelectedMessages() async {
        guard !selectedMessages.isEmpty else { return }

        let ids = allMessages
            .filter { selectedMessages.contains($0.id) }
            .map(\.messageId)

        isLoading = true
        statusMessage = "Eliminando \(ids.count) correos..."

        do {
            let count = try await bridge.deleteMessages(
                ids: ids,
                mailbox: currentMailbox,
                account: currentAccount
            )
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
        let ids = sender.messages.map(\.messageId)

        isLoading = true
        statusMessage = "Eliminando \(ids.count) correos de \(sender.displayName)..."

        do {
            let count = try await bridge.deleteMessages(
                ids: ids,
                mailbox: currentMailbox,
                account: currentAccount
            )
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

        let ids = allMessages
            .filter { selectedMessages.contains($0.id) }
            .map(\.messageId)

        isLoading = true
        statusMessage = "Moviendo \(ids.count) correos a \(targetMailbox)..."

        do {
            let count = try await bridge.moveMessages(
                ids: ids,
                fromMailbox: currentMailbox,
                toMailbox: targetMailbox,
                account: currentAccount
            )
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
        let ids = sender.messages.map(\.messageId)

        isLoading = true
        statusMessage = "Moviendo \(ids.count) correos de \(sender.displayName) a \(targetMailbox)..."

        do {
            let count = try await bridge.moveMessages(
                ids: ids,
                fromMailbox: currentMailbox,
                toMailbox: targetMailbox,
                account: currentAccount
            )
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
