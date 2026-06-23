import SwiftUI

/// Reader-mode sidebar: account + mailbox (folder) navigation, like a standard
/// mail client. Each account is a collapsible group under its name (like Mail).
struct MailboxSidebarView: View {
    @EnvironmentObject var manager: MailManager
    @State private var expandedAccounts: Set<String> = []
    @State private var didInit = false

    var body: some View {
        List {
            if !commonMailboxes.isEmpty {
                Section("Todas las cuentas") {
                    ForEach(commonMailboxes, id: \.self) { mb in
                        mailboxRow(account: nil, mailbox: mb)
                    }
                }
            }

            Section("Cuentas") {
                ForEach(manager.accounts) { account in
                    DisclosureGroup(isExpanded: expansion(for: account.name)) {
                        ForEach(ordered(account.mailboxes), id: \.self) { mb in
                            mailboxRow(account: account.name, mailbox: mb)
                        }
                    } label: {
                        Label(account.name, systemImage: "person.crop.circle")
                            .lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 240)
        .onAppear {
            guard !didInit else { return }
            didInit = true
            // Start with the active account expanded (or the first one).
            if let acc = manager.currentAccount {
                expandedAccounts.insert(acc)
            } else if let first = manager.accounts.first {
                expandedAccounts.insert(first.name)
            }
        }
    }

    /// Main mailbox names that exist across accounts, in a sensible order.
    private var commonMailboxes: [String] {
        let priority = ["INBOX", "Sent Messages", "Drafts", "Archive", "Junk", "Deleted Messages"]
        let all = Set(manager.accounts.flatMap(\.mailboxes))
        return priority.filter { all.contains($0) }
    }

    private func expansion(for account: String) -> Binding<Bool> {
        Binding(
            get: { expandedAccounts.contains(account) },
            set: { isOpen in
                if isOpen { expandedAccounts.insert(account) }
                else { expandedAccounts.remove(account) }
            }
        )
    }

    private func mailboxRow(account: String?, mailbox: String) -> some View {
        let isSelected = manager.currentAccount == account && manager.currentMailbox == mailbox
        return Button {
            Task { await manager.openMailbox(account: account, mailbox: mailbox) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: mailbox))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(displayName(mailbox))
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    /// Orders a single account's mailboxes the way Mail/Spark do: INBOX first,
    /// then the standard special mailboxes, then custom folders alphabetically.
    private func ordered(_ mailboxes: [String]) -> [String] {
        func rank(_ name: String) -> Int {
            let l = name.lowercased()
            if l.contains("inbox") { return 0 }
            if l.contains("draft") || l.contains("borrador") { return 1 }
            if l.contains("sent") || l.contains("enviado") { return 2 }
            if l.contains("junk") || l.contains("spam") { return 3 }
            if l.contains("trash") || l.contains("deleted") || l.contains("papelera") { return 4 }
            if l.contains("archive") || l.contains("archivo") { return 5 }
            return 100
        }
        return mailboxes.sorted {
            let r0 = rank($0), r1 = rank($1)
            if r0 != r1 { return r0 < r1 }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Friendly Spanish display name for the common mailboxes (keeps the real
    /// name for selection).
    private func displayName(_ name: String) -> String {
        switch name.lowercased() {
        case "inbox": return "Entrada"
        case "sent messages", "sent": return "Enviados"
        case "drafts": return "Borradores"
        case "deleted messages", "trash": return "Papelera"
        case "junk": return "No deseado"
        case "archive": return "Archivo"
        default: return name
        }
    }

    private func icon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("inbox") { return "tray.fill" }
        if lower.contains("sent") { return "paperplane.fill" }
        if lower.contains("draft") || lower.contains("borrador") { return "pencil" }
        if lower.contains("trash") || lower.contains("deleted") || lower.contains("papelera") { return "trash.fill" }
        if lower.contains("junk") || lower.contains("spam") { return "xmark.bin.fill" }
        if lower.contains("archive") || lower.contains("archivo") { return "archivebox.fill" }
        return "folder.fill"
    }
}
