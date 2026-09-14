import Foundation
import Testing
@testable import SuperEmailAi

/// A throwaway preference domain, removed afterwards. Never touches the real «SuperEmailAi» one.
private func withScratchDefaults(_ body: (UserDefaults) -> Void) {
    let name = "SuperEmailAiTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    body(defaults)
    defaults.removePersistentDomain(forName: name)
}

@Test func copiesOnlyWhatTheAppDoesNotHaveYet() {
    withScratchDefaults { defaults in
        defaults.set("nuevo", forKey: "autoReplyMessage")
        let copied = PreferencesMigration.migrate(["autoReplyMessage": "viejo", "importantSenders": ["a@x.com"]], into: defaults)
        #expect(copied == ["importantSenders"])
        #expect(defaults.string(forKey: "autoReplyMessage") == "nuevo")
        #expect(defaults.stringArray(forKey: "importantSenders") == ["a@x.com"])
    }
}

@Test func migratesOnlyInsideTheAppAndOnlyOnce() {
    withScratchDefaults { defaults in
        PreferencesMigration.runIfNeeded(defaults: defaults, bundleIdentifier: nil, legacy: { ["a": 1] })
        #expect(defaults.object(forKey: "a") == nil)

        PreferencesMigration.runIfNeeded(defaults: defaults, bundleIdentifier: "com.obsidiaan.superemailai", legacy: { ["a": 1] })
        #expect(defaults.integer(forKey: "a") == 1)

        defaults.removeObject(forKey: "a")
        PreferencesMigration.runIfNeeded(defaults: defaults, bundleIdentifier: "com.obsidiaan.superemailai", legacy: { ["a": 2] })
        #expect(defaults.object(forKey: "a") == nil)
    }
}

@Test func aMissingOldDomainStillCountsAsMigrated() {
    withScratchDefaults { defaults in
        PreferencesMigration.runIfNeeded(defaults: defaults, bundleIdentifier: "com.obsidiaan.superemailai", legacy: { nil })
        #expect(defaults.bool(forKey: PreferencesMigration.doneKey))
    }
}
