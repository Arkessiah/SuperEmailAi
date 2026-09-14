import Foundation

/// Settings saved while the app ran as a bare executable live in the preference domain named
/// after the executable («SuperEmailAi», inferred). As a `.app` the domain is the bundle id, so
/// the first bundled launch copies them over — only keys the app doesn't have yet, and without
/// deleting the old domain. Must run before `MailManager` reads its settings.
enum PreferencesMigration {
    static let legacyDomain = "SuperEmailAi"
    static let doneKey = "legacyPreferencesMigrated"

    static func runIfNeeded(defaults: UserDefaults = .standard,
                            bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                            legacy: () -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: legacyDomain) }) {
        guard let bundleIdentifier, bundleIdentifier != legacyDomain, !defaults.bool(forKey: doneKey) else { return }
        migrate(legacy() ?? [:], into: defaults)
        defaults.set(true, forKey: doneKey)
    }

    /// Copies the keys `defaults` doesn't have; returns them, sorted.
    @discardableResult
    static func migrate(_ legacy: [String: Any], into defaults: UserDefaults) -> [String] {
        let missing = legacy.keys.filter { defaults.object(forKey: $0) == nil }.sorted()
        for key in missing { defaults.set(legacy[key], forKey: key) }
        return missing
    }
}
