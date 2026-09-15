import Testing
@testable import SuperEmailAi

@Test func importantSendersAreAlwaysAnswered() {
    #expect(AutoReplyPolicy.mayAnswer(scope: .importantOnly, isImportant: true, hasWrittenTo: false))
    #expect(AutoReplyPolicy.mayAnswer(scope: .all, isImportant: true, hasWrittenTo: false))
}

@Test func toEveryoneMeansEveryoneYouHaveWrittenTo() {
    #expect(AutoReplyPolicy.mayAnswer(scope: .all, isImportant: false, hasWrittenTo: true))
    #expect(!AutoReplyPolicy.mayAnswer(scope: .all, isImportant: false, hasWrittenTo: false))
}

@Test func onlyImportantIgnoresPastContact() {
    #expect(!AutoReplyPolicy.mayAnswer(scope: .importantOnly, isImportant: false, hasWrittenTo: true))
}
