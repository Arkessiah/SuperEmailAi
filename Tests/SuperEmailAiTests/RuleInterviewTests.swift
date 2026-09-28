import Foundation
import Testing
@testable import SuperEmailAi

/// A model that answers whatever the test decides, per question, and remembers what it was asked.
/// The count of questions matters as much as the answers: the whole point of the interview is that
/// it asks few, and only about what the sentence left open.
final class ScriptedModel: LanguageModel, @unchecked Sendable {
    var availability: ModelAvailability = .ready
    /// Given the question and the options, what to answer. The default picks the first option.
    var reply: (ModelPrompt, [String]) -> String = { _, options in options[0] }
    private(set) var questions: [String] = []

    func answer(_ prompt: ModelPrompt) async throws -> String { "" }

    func choose(_ prompt: ModelPrompt, from options: [String]) async throws -> String {
        questions.append(prompt.task)
        return reply(prompt, options)
    }
}

private let mailboxes = ["INBOX", "Facturas", "Archivo"]

/// Answers a question by the first option that appears in the script, so a test can say «for the
/// action, borrar; for everything else, the default».
private func saying(_ script: [String]) -> (ModelPrompt, [String]) -> String {
    { _, options in script.first(where: options.contains) ?? options[0] }
}

@Test @MainActor func theSentenceKeepsItsConditionsAndOnlyTwoQuestionsAreAsked() async throws {
    let model = ScriptedModel()
    model.reply = saying(["borrar", "todas"])
    let interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)

    let rule = try await interview.rule(from: "borra los boletines de más de 30 días")

    // The condition the model dropped two runs out of three when it composed the rule itself.
    #expect(rule.conditions == [.senderInNewsletters, .olderThanDays(30)])
    #expect(rule.action == .delete)
    #expect(rule.matchMode == .all)
    #expect(!rule.isEnabled)
    #expect(rule.name == "Borrar boletines, de más de 30 días")
    // Only the action and «todas»: neither condition needed asking, they were in the sentence.
    #expect(model.questions.count == 2, "preguntó \(model.questions.count) veces: \(model.questions)")
}

@Test @MainActor func aDeleteThatCouldFireOnTheClockAloneIsRefused() async {
    let model = ScriptedModel()
    model.reply = saying(["borrar"])
    let interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)

    // Nothing but an age: this rule empties the account as the mail gets old.
    await #expect(throws: ModelError.self) {
        try await interview.rule(from: "borra los correos de más de 30 días")
    }
}

@Test @MainActor func withAtLeastOneConditionADeleteByAgeIsRefusedToo() async {
    let model = ScriptedModel()
    model.reply = saying(["borrar", "al menos una"])
    let interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)

    // «boletines O más de 30 días» does the same damage with the newsletter condition still there.
    await #expect(throws: ModelError.self) {
        try await interview.rule(from: "borra los boletines de más de 30 días")
    }
}

@Test @MainActor func aMailboxNamedInTheSentenceIsNotAskedAbout() async throws {
    let model = ScriptedModel()
    model.reply = saying(["mover a una carpeta"])
    let interview = RuleInterview(model: model, accounts: ["Trabajo"], mailboxes: mailboxes)

    let rule = try await interview.rule(from: "mueve a Facturas los correos de gestoria-lopez.es")

    #expect(rule.action == .move(account: "Trabajo", mailbox: "Facturas"))
    #expect(rule.conditions == [.domainIs("gestoria-lopez.es")])
    #expect(model.questions.count == 1, "la carpeta estaba en la frase: \(model.questions)")
}

@Test @MainActor func withSeveralAccountsTheUserPicksAndTheModelIsNotAsked() async {
    let model = ScriptedModel()
    model.reply = saying(["mover a una carpeta"])
    let interview = RuleInterview(model: model, accounts: ["iCloud", "Trabajo"], mailboxes: mailboxes)

    // The sentence says the folder and not the account. Guessing would move mail out of sight.
    await #expect(throws: ModelError.missingAccount(mailbox: "Facturas")) {
        try await interview.rule(from: "mueve a Facturas los correos de gestoria-lopez.es")
    }
}

@Test @MainActor func aFolderThatIsNotNamedIsAskedFor() async throws {
    let model = ScriptedModel()
    model.reply = saying(["mover a una carpeta", "Archivo"])
    let interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)

    let rule = try await interview.rule(from: "mueve los correos de gestoria-lopez.es a su sitio")

    #expect(rule.action == .move(account: "iCloud", mailbox: "Archivo"))
    #expect(model.questions.count == 2)
    #expect(model.questions.contains { $0.contains("carpeta") })
}

@Test @MainActor func whatNeededJudgementIsAskedAndAnswerIsObeyed() async throws {
    let model = ScriptedModel()
    model.reply = saying(["ponerle una bandera", "sí"])
    let interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)

    let rule = try await interview.rule(from: "ponle bandera a los correos que digan «vencimiento»")

    #expect(rule.conditions == [.subjectContains("vencimiento")])
    #expect(model.questions.contains { $0.contains("vencimiento") })
}

@Test @MainActor func aNoLeavesNothingToBuildARuleWith() async {
    let model = ScriptedModel()
    model.reply = saying(["ponerle una bandera", "no"])
    let interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)

    await #expect(throws: ModelError.unclearInstruction) {
        try await interview.rule(from: "ponle bandera a los correos que digan «vencimiento»")
    }
}

@Test @MainActor func aSentenceWithNothingInItIsSaidSoAndNotGuessed() async {
    let model = ScriptedModel()
    let interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)

    await #expect(throws: ModelError.unclearInstruction) {
        try await interview.rule(from: "haz algo con mi correo, por favor")
    }
}

@Test @MainActor func nothingIsAskedWithoutAModel() async {
    let model = ScriptedModel()
    model.availability = .notEnabled
    let interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)

    await #expect(throws: ModelError.unavailable(.notEnabled)) {
        try await interview.rule(from: "borra los boletines")
    }
    #expect(model.questions.isEmpty)
}

// MARK: - The scope it is born with

@Test @MainActor func theRuleIsBornLookingWhereTheUserWasLooking() async throws {
    let model = ScriptedModel()
    model.reply = saying(["archivar"])
    var interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)
    interview.scope = [.accountIs("iCloud"), .mailboxIs("INBOX")]

    let rule = try await interview.rule(from: "archiva los boletines")

    #expect(rule.conditions == [.accountIs("iCloud"), .mailboxIs("INBOX"), .senderInNewsletters])
    // The name says what the rule picks, not where it looks.
    #expect(rule.name == "Archivar boletines")
    // And the scope is not one more alternative to weigh, so it asked nothing about «todas».
    #expect(model.questions.count == 1, "preguntó de más: \(model.questions)")
}

@Test @MainActor func theScopeDoesNotExcuseADeleteByAgeAlone() async {
    let model = ScriptedModel()
    model.reply = saying(["borrar"])
    var interview = RuleInterview(model: model, accounts: ["iCloud"], mailboxes: mailboxes)
    interview.scope = [.accountIs("iCloud"), .mailboxIs("INBOX")]

    // Two conditions that aren't about the clock are in there, and it is still «delete every old
    // mail in this mailbox».
    await #expect(throws: ModelError.self) {
        try await interview.rule(from: "borra los correos de más de 30 días")
    }
}

@Test func aRuleWithNothingButItsScopeIsRefused() {
    // It would pick every single mail in that mailbox.
    let rule = Rule(name: "x", isEnabled: false, position: 0, matchMode: .all,
                    conditions: [.accountIs("iCloud"), .mailboxIs("INBOX")], action: .archive)
    #expect(throws: ModelError.unclearInstruction) { try RuleSafety.vet(rule) }
}

// MARK: - The safety net on its own

@Test func markingAsReadDropsTheConditionThatWouldAnnulTheRule() throws {
    let rule = Rule(name: "x", isEnabled: false, position: 0, matchMode: .all,
                    conditions: [.domainIs("github.com"), .isRead(true)], action: .markRead)
    let vetted = try RuleSafety.vet(rule)
    #expect(vetted.conditions == [.domainIs("github.com")])
    // And the name is rebuilt, or it would describe a condition that is no longer there.
    #expect(vetted.name == "Marcar como leído de github.com")
}

@Test func markingAsReadWithNothingElseLeftIsRefused() {
    let rule = Rule(name: "x", isEnabled: false, position: 0, matchMode: .all,
                    conditions: [.isRead(true)], action: .markRead)
    #expect(throws: ModelError.unclearInstruction) { try RuleSafety.vet(rule) }
}

@Test func aRuleTheUserWroteKeepsItsShape() throws {
    // Everything else passes through untouched: the net catches the AI's mistakes, it doesn't
    // second-guess a rule that says what it says.
    let rule = Rule(name: "Mis boletines", isEnabled: true, position: 3, matchMode: .any,
                    conditions: [.senderInNewsletters, .isRead(true)], action: .archive)
    #expect(try RuleSafety.vet(rule) == rule)
}
