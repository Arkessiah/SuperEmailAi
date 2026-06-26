import Foundation

struct MailMessage: Identifiable, Hashable, Codable {
    let id: String
    let subject: String
    let sender: String
    let senderAddress: String
    let dateSent: Date
    let dateReceived: Date
    let isRead: Bool
    let mailbox: String
    let account: String
    let messageId: Int
    var size: Int = 0   // bytes (0 if unknown)

    /// Human-readable size (KB/MB).
    var sizeText: String {
        guard size > 0 else { return "" }
        let mb = Double(size) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(size) / 1024
        return String(format: "%.0f KB", max(kb, 1))
    }

    var senderDomain: String {
        guard let atIndex = senderAddress.lastIndex(of: "@") else { return senderAddress }
        return String(senderAddress[senderAddress.index(after: atIndex)...])
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MailMessage, rhs: MailMessage) -> Bool {
        lhs.id == rhs.id
    }

    /// Returns a copy with a different read state (struct has `let` fields).
    func with(isRead newValue: Bool) -> MailMessage {
        MailMessage(
            id: id, subject: subject, sender: sender, senderAddress: senderAddress,
            dateSent: dateSent, dateReceived: dateReceived, isRead: newValue,
            mailbox: mailbox, account: account, messageId: messageId, size: size
        )
    }
}

enum MailCategory: String, CaseIterable {
    case personas = "Personas"
    case boletines = "Boletines"
    case notificaciones = "Notificaciones"
}

extension MailMessage {
    /// Heuristic Smart-Inbox bucket based on the sender (no headers needed).
    /// A future on-device AI / List-Unsubscribe parsing can refine this.
    var category: MailCategory {
        let full = "\(sender) \(senderAddress)".lowercased()
        let local = senderAddress.split(separator: "@").first.map { $0.lowercased() } ?? ""

        let notification = ["no-reply", "noreply", "no_reply", "donotreply", "do-not-reply",
                            "do_not_reply", "notification", "notifications", "mailer-daemon",
                            "postmaster", "bounce", "automated", "auto-confirm", "alert"]
        if notification.contains(where: { local.contains($0) || full.contains($0) }) {
            return .notificaciones
        }

        let newsletter = ["newsletter", "marketing", "promo", "promotion", "offers", "deals",
                          "mailing", "campaign", "news@", "updates@", "digest", "boletin", "noticias"]
        if newsletter.contains(where: { local.contains($0) || full.contains($0) }) {
            return .boletines
        }

        return .personas
    }
}

struct SenderGroup: Identifiable {
    let id: String
    let address: String
    let displayName: String
    let domain: String
    let messages: [MailMessage]

    var count: Int { messages.count }
    var unreadCount: Int { messages.filter { !$0.isRead }.count }
    var latestDate: Date { messages.map(\.dateReceived).max() ?? Date.distantPast }
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let subject: String
    let sender: String
    let messages: [MailMessage]
    var count: Int { messages.count }
}

struct MailAccount: Identifiable, Hashable, Codable {
    let id: String        // account name (unique in Mail.app)
    let name: String
    let mailboxes: [String]

    init(name: String, mailboxes: [String]) {
        self.id = name
        self.name = name
        self.mailboxes = mailboxes
    }
}
