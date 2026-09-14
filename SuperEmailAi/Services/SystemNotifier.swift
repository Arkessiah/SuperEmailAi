import AppKit
import UserNotifications

/// Title and body of a notification, apart from UserNotifications so it can be tested.
struct NotificationText: Equatable {
    var title: String
    var body: String
    var messageID: String?

    static func newMail(_ message: MailMessage) -> NotificationText {
        NotificationText(title: message.sender.isEmpty ? message.senderAddress : message.sender,
                         body: message.subject.isEmpty ? "(sin asunto)" : message.subject,
                         messageID: message.id)
    }

    static func pausedRule(_ notice: RuleNotice) -> NotificationText {
        NotificationText(title: "Regla en pausa: \(notice.ruleName)", body: notice.message)
    }
}

private let messageIDKey = "messageID"

/// Native macOS notifications for the alerts (ARK-204). Only inside the `.app`: without a bundle
/// id UserNotifications throws, so under `swift run` the in-app bell is all there is.
@MainActor
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Opens the mail behind a clicked notification. A click that arrives before this is set
    /// (the app launched by the click) waits for it.
    var onOpenMessage: ((String) -> Void)? {
        didSet {
            guard let id = pendingMessageID, let onOpenMessage else { return }
            pendingMessageID = nil
            onOpenMessage(id)
        }
    }
    private var pendingMessageID: String?

    /// Asks for permission the first time; afterwards macOS remembers the answer.
    func start() {
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ text: NotificationText) {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        if let id = text.messageID { content.userInfo = [messageIDKey: id] }
        let request = UNNotificationRequest(identifier: text.messageID ?? UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let messageID = response.notification.request.content.userInfo[messageIDKey] as? String
        completionHandler()
        Task { @MainActor in SystemNotifier.shared.open(messageID) }
    }

    private func open(_ messageID: String?) {
        NSApp.activate()
        guard let messageID else { return }
        if let onOpenMessage { onOpenMessage(messageID) } else { pendingMessageID = messageID }
    }
}
