import Foundation

/// Threading headers of one message (ARK-209). Message-IDs are kept without `<>`, as Mail's
/// `message id` property gives them, so both sources compare equal.
struct ThreadHeaders: Equatable {
    var messageId: String?
    var inReplyTo: String?
    var references: [String]
}

/// Addresses a sent message went to (lowercased).
struct SentMessage: Equatable {
    var message: MailMessage
    var to: [String]
    var cc: [String]
}
