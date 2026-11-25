import Foundation
import Testing

@testable import MurmurTyping

/// The strip with a language model's prediction in hand. The predictions here are written by
/// hand, so these run without the model's files; `NextWordPredictorTests` covers the real one.
@Suite struct PredictionSuggestionTests {
    private func model() throws -> TypingModel { try TypingModel.bundled() }

    /// A prediction at `boundary` that gives each word the probability beside it.
    private func prediction(_ boundary: String, _ scores: [String: Float]) throws -> WordPrediction {
        let model = try model()
        var ids: [Int: Float] = [:]
        for (word, score) in scores { ids[try #require(model.id(of: word), "\(word) is not in the model")] = score }
        return WordPrediction(boundary: boundary, scores: ids)
    }

    private func texts(_ text: String, _ prediction: WordPrediction?, capitalisesStarts: Bool = true) throws -> [String] {
        try SuggestionEngine.suggestions(
            before: text, model: model(), prediction: prediction, capitalisesStarts: capitalisesStarts
        ).map(\.text)
    }

    @Test func bestAndCandidatesAreOrdered() throws {
        let model = try model()
        let answer = try prediction("x ", ["has": 0.1, "had": 0.3, "is": 0.5, "zebra": 0.0])
        #expect(answer.best.map { model.word($0.id) } == ["is", "had", "has"], "zero probability is no candidate")
        let ha = answer.candidates(in: model.range(ofPrefix: "ha")).map { model.word($0.id) }
        #expect(ha == ["had", "has"], "a prefix's candidates come in id order")
        #expect(answer.candidates(in: model.range(ofPrefix: "q")).isEmpty)
    }

    @Test func nextWordsComeFromThePrediction() throws {
        let answer = try prediction("my dog ", ["is": 0.3, "was": 0.2, "has": 0.1, "loves": 0.05])
        // Strip order: runner-up, best, third.
        #expect(try texts("my dog ", answer) == ["was", "is", "has"])
        #expect(try texts("my dog ", answer).count == 3)
    }

    @Test func aPredictionForAnotherBoundaryIsIgnored() throws {
        let answer = try prediction("my cat ", ["is": 0.3, "was": 0.2, "has": 0.1])
        #expect(try texts("my dog ", answer) == texts("my dog ", nil))
        #expect(try texts("my dog h", answer) == texts("my dog h", nil))
    }

    @Test func neverVolunteeredWordsStayOutHoweverLikely() throws {
        let answer = try prediction("my dog ", ["sex": 0.9, "is": 0.05, "was": 0.03, "has": 0.01])
        let strip = try texts("my dog ", answer)
        #expect(strip == ["was", "is", "has"])
        // Typed, the word still completes.
        let typed = try prediction("my dog ", ["sex": 0.9, "seems": 0.05])
        #expect(try texts("my dog se", typed).contains("sex"))
    }

    @Test func thePreviousWordIsNotOfferedAgain() throws {
        let answer = try prediction("my dog ", ["dog": 0.5, "is": 0.1, "a": 0.05, "was": 0.01])
        #expect(try texts("my dog ", answer) == ["a", "is", "was"])
    }

    @Test func aWrittenPairIsNotOfferedAgainAndAUsedWordIsHeldBack() throws {
        let text = "the same time to the "
        let answer = try prediction(text, ["same": 0.6, "time": 0.2, "first": 0.1, "end": 0.05])
        let strip = try texts(text, answer)
        #expect(!strip.contains("same"), "\"the same\" is already written")
        // "time" was used, so it keeps 5% of its 0.2 and falls behind "first" and "end".
        #expect(strip == ["end", "first", "time"])
    }

    @Test func aShortPredictionIsFilledFromThePairModel() throws {
        let answer = try prediction("my dog ", ["barked": 0.4])
        let strip = try texts("my dog ", answer)
        #expect(strip.count == 3)
        #expect(strip[1] == "barked", "the model's word takes the centre")
        #expect(Set(strip).count == 3)
        for word in strip { #expect(!SuggestionEngine.neverVolunteered.contains(word)) }
    }

    @Test func completionsAreRankedByThePredictionFirst() throws {
        let answer = try prediction("my dog ", ["has": 0.1, "had": 0.05, "happy": 0.2, "is": 0.5])
        #expect(try texts("my dog ha", answer) == ["ha", "happy", "has"])
        // The typed case carries over.
        #expect(try texts("my dog Ha", answer) == ["Ha", "Happy", "Has"])
    }

    @Test func theTypedWordIsNeverItsOwnCompletion() throws {
        let answer = try prediction("my dog ", ["is": 0.5, "island": 0.01, "isn't": 0.2])
        let strip = try texts("my dog is", answer)
        #expect(strip.first == "is")
        #expect(!strip.dropFirst().contains("is"))
        #expect(strip.dropFirst().contains("island"))
    }

    @Test func completionsThePredictionLacksComeFromThePairModel() throws {
        let answer = try prediction("my dog ", ["happy": 0.2])
        let strip = try texts("my dog ha", answer)
        #expect(strip.count == 3)
        #expect(strip[1] == "happy")
        #expect(strip[2] != "happy")
        let none = try prediction("my dog ", ["is": 0.5])
        #expect(try texts("my dog ha", none) == texts("my dog ha", nil))
    }

    @Test func aContractionWaitsForItsStem() throws {
        let answer = try prediction("i ", ["don't": 0.5, "do": 0.2, "did": 0.1])
        #expect(try texts("i d", answer) == ["d", "do", "did"], "0.5 x 0.1 is behind 0.2 and 0.1")
        #expect(try texts("i don", answer).contains("don't"))
    }

    @Test func aSentenceStartIsPredictedAndCapitalisedOnRequest() throws {
        let afterSentence = "i got a bit lost. "
        let answer = try prediction(afterSentence, ["sorry": 0.4, "i": 0.3, "the": 0.1])
        #expect(try texts(afterSentence, answer) == ["I", "Sorry", "The"])
        #expect(try texts(afterSentence, answer, capitalisesStarts: false) == ["I", "sorry", "the"])
        // With no prediction the fixed openers are what they were.
        #expect(try texts(afterSentence, nil) == ["The", "I", "I'm"])
        #expect(try texts(afterSentence, nil, capitalisesStarts: false) == ["The", "I", "I'm"])
        let empty = try prediction("", ["hello": 0.4, "hi": 0.3, "thanks": 0.1])
        #expect(try texts("", empty) == ["Hi", "Hello", "Thanks"])
    }

    @Test func midSentenceWordsKeepTheirCase() throws {
        let answer = try prediction("my dog ", ["is": 0.3, "i": 0.2, "i'm": 0.1])
        #expect(try texts("my dog ", answer) == ["I", "is", "I'm"])
    }

    @Test func theBoundaryIsTheTextLessTheTypedLetters() {
        #expect(SuggestionEngine.boundary(before: "my dog ") == "my dog ")
        #expect(SuggestionEngine.boundary(before: "my dog ha") == "my dog ")
        #expect(SuggestionEngine.boundary(before: "") == "")
        #expect(SuggestionEngine.boundary(before: "don't") == "")
        #expect(SuggestionEngine.boundary(before: "wait.") == nil)
        #expect(SuggestionEngine.boundary(before: "wait. ") == "wait. ")
        #expect(SuggestionEngine.typedLength(before: "my dog ha") == 2)
        #expect(SuggestionEngine.typedLength(before: "room 3") == nil)
    }

    @Test func aCorrectionStillTakesTheCentre() throws {
        let answer = try prediction("my dog ", ["has": 0.1, "happy": 0.2])
        let strip = try SuggestionEngine.suggestions(before: "my dog ha", model: model(), prediction: answer)
        let merged = SuggestionEngine.merging(correction: "had", into: strip)
        #expect(merged.map(\.text) == ["ha", "had", "happy"])
        #expect(merged.map(\.kind) == [.typed, .correction, .completion])
    }
}
