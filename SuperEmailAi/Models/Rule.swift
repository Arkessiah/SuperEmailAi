import Foundation

/// A user rule (ARK-202): conditions + one action + "always"/"never" sender lists.
/// Stored as JSON, so new condition kinds (e.g. an AI condition in phase 2) can be
/// added without migrating data.
struct Rule: Identifiable, Codable, Equatable {
    enum MatchMode: String, Codable { case all, any }

    var id: String = UUID().uuidString
    var name: String
    var isEnabled: Bool = false
    var position: Int = 0
    var matchMode: MatchMode = .all
    var conditions: [RuleCondition] = []
    var action: RuleAction
    var alwaysSenders: [SenderEntry] = []
    var neverSenders: [SenderEntry] = []
    /// Automatic runs only touch mail received after the rule was enabled.
    var enabledAt: Date?
    /// Set by the safety brake or by repeated failures; the rule doesn't run until resumed.
    var pausedReason: String?
    var consecutiveFailures: Int = 0
}

/// An "always"/"never" entry and where it came from (phase 2 adds `.ai`).
struct SenderEntry: Codable, Equatable, Hashable {
    enum Origin: String, Codable { case manual, correction, ai }
    var address: String
    var origin: Origin
}

/// Conditions over data already in the index (no Mail.app round-trip).
enum RuleCondition: Codable, Equatable {
    case senderContains(String)
    case senderIs(String)
    case domainIs(String)
    case subjectContains(String)
    case olderThanDays(Int)
    case newerThanDays(Int)
    case isRead(Bool)
    case accountIs(String)
    case mailboxIs(String)
    case largerThanKB(Int)
    case senderInImportant
    case senderInNewsletters
}

enum RuleAction: Codable, Equatable {
    case move(account: String, mailbox: String)
    case archive
    case delete
    case markRead
    case flag

    /// Actions that take mail out of its mailbox: they count for the safety brake.
    var isDisplacing: Bool {
        switch self {
        case .move, .archive, .delete: true
        case .markRead, .flag: false
        }
    }
}
