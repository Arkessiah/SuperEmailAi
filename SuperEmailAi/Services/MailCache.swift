import Foundation

/// Lightweight on-disk JSON cache of recent messages (per account+mailbox) and
/// the accounts list, so the UI can render instantly on launch / navigation and
/// refresh from Mail.app in the background.
///
/// Stored at `~/Library/Application Support/SuperEmailAi/cache.json`.
final class MailCache {

    static let shared = MailCache()

    /// Max messages kept per account+mailbox key (the most recent ones).
    private let maxPerKey = 300

    private let fileURL: URL
    private var store: CacheData

    private struct CacheData: Codable {
        var accounts: [MailAccount] = []
        var messages: [String: [MailMessage]] = [:]   // key = "account|mailbox"
    }

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SuperEmailAi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("cache.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(CacheData.self, from: data) {
            store = decoded
        } else {
            store = CacheData()
        }
    }

    private static func key(account: String?, mailbox: String) -> String {
        "\(account ?? "ALL")|\(mailbox)"
    }

    // MARK: - Accounts

    var accounts: [MailAccount] { store.accounts }

    func setAccounts(_ accounts: [MailAccount]) {
        store.accounts = accounts
        save()
    }

    // MARK: - Messages

    func messages(account: String?, mailbox: String) -> [MailMessage]? {
        store.messages[Self.key(account: account, mailbox: mailbox)]
    }

    func update(_ messages: [MailMessage], account: String?, mailbox: String) {
        let trimmed = Array(
            messages.sorted { $0.dateReceived > $1.dateReceived }.prefix(maxPerKey)
        )
        store.messages[Self.key(account: account, mailbox: mailbox)] = trimmed
        save()
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = store
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
