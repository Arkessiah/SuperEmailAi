import Foundation

struct MailMessage: Identifiable, Hashable {
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

struct MailAccount: Identifiable, Hashable {
    let id: String        // account name (unique in Mail.app)
    let name: String
    let mailboxes: [String]

    init(name: String, mailboxes: [String]) {
        self.id = name
        self.name = name
        self.mailboxes = mailboxes
    }
}
