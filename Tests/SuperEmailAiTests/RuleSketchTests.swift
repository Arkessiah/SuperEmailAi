import Foundation
import Testing
@testable import SuperEmailAi

private let accounts = ["iCloud", "Trabajo"]
private let mailboxes = ["INBOX", "Facturas", "Archivo"]

private func read(_ instruction: String) -> RuleSketch {
    RuleSketch.read(instruction, accounts: accounts, mailboxes: mailboxes)
}

@Test func theNewsletterAndTheAgeBothSurvive() {
    // The one the model kept losing, and the reason this parser exists.
    let sketch = read("borra los boletines de más de 30 días")
    #expect(sketch.certain.contains(.senderInNewsletters))
    #expect(sketch.certain.contains(.olderThanDays(30)))
    #expect(sketch.uncertain.isEmpty)
}

@Test func anAddressBeatsADomainAndADomainIsEnough() {
    #expect(read("borra lo de ofertas@tienda.com").certain == [.senderIs("ofertas@tienda.com")])
    #expect(read("mueve a Facturas los correos de gestoria-lopez.es").certain
            == [.domainIs("gestoria-lopez.es")])
    #expect(read("archiva lo de @github.com").certain == [.domainIs("github.com")])
}

@Test func theMailboxIsOneTheUserReallyHas() {
    #expect(read("mueve a Facturas lo de la gestoría").mailboxes == ["Facturas"])
    // A folder that doesn't exist is not a mailbox, it's a word in a sentence.
    #expect(read("mueve a Recibos lo de la gestoría").mailboxes.isEmpty)
    #expect(read("archiva lo viejo de Trabajo").accounts == ["Trabajo"])
}

@Test func markingAsReadIsNotACondition() {
    // «leídos» here says what to do, not which mail. Read as a condition it gives a rule that only
    // touches mail already read — one that does nothing.
    let sketch = read("marca como leídos los avisos de notificaciones@ejemplo.com")
    #expect(!sketch.certain.contains(.isRead(true)))
    #expect(sketch.certain == [.senderIs("notificaciones@ejemplo.com")])
    // Said about the mail to pick, it is a condition again.
    #expect(read("borra los boletines ya leídos").certain.contains(.isRead(true)))
    #expect(read("archiva los correos sin leer de hace un mes").certain.contains(.isRead(false)))
}

@Test func daysWeeksMonthsAndYears() {
    #expect(read("borra lo de más de 6 meses").certain == [.olderThanDays(180)])
    #expect(read("borra lo de más de un año").certain == [.olderThanDays(365)])
    #expect(read("archiva lo de más de dos semanas").certain == [.olderThanDays(14)])
    // «última semana» is the opposite condition built from the same words.
    #expect(read("marca los correos de la última semana").certain == [.newerThanDays(7)])
}

@Test func aWordThatMerelyStartsLikeAUnitIsNotOne() {
    // «mesa» begins with «mes»; thirty days out of nowhere would be a rule nobody asked for.
    #expect(read("borra los correos que hablen de la mesa nueva").certain.isEmpty)
}

@Test func sizesInKBAndMB() {
    #expect(read("archiva lo que pese más de 5 MB").certain == [.largerThanKB(5000)])
    #expect(read("archiva lo de más de 500 kb").certain == [.largerThanKB(500)])
    #expect(read("borra los adjuntos de 2gb").certain == [.largerThanKB(2_000_000)])
}

@Test func twoConditionsInOneSentence() {
    let sketch = read("archiva lo que pese más de 5 MB y tenga más de un año")
    #expect(sketch.certain == [.olderThanDays(365), .largerThanKB(5000)])
}

@Test func whatNeedsJudgementIsAskedAndNotAssumed() {
    // A quoted word could be a subject, a folder or just emphasis, so it gets asked.
    let quoted = read("mueve a Facturas los correos que digan «vencimiento»")
    #expect(quoted.certain.isEmpty)
    #expect(quoted.uncertain.map(\.condition) == [.subjectContains("vencimiento")])
    #expect(quoted.uncertain[0].evidence.contains("vencimiento"))

    // «importantes» may mean the list or nothing at all.
    let important = read("no borres nunca los correos importantes")
    #expect(important.uncertain.map(\.condition) == [.senderInImportant])
}

@Test func nothingIsInventedFromAnEmptySentence() {
    #expect(read("").candidates.isEmpty)
    #expect(read("haz algo con mi correo, por favor").candidates.isEmpty)
}
