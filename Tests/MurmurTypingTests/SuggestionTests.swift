import Foundation
import Testing

@testable import MurmurTyping

@Suite struct SuggestionTests {
    private func model() throws -> TypingModel { try TypingModel.bundled() }

    private func texts(_ text: String) throws -> [String] {
        try SuggestionEngine.suggestions(before: text, model: model()).map(\.text)
    }

    /// The text after a tap on `suggestion`, the way the controller applies its edit.
    private func apply(_ suggestion: Suggestion, to text: String) -> String {
        let edit = SuggestionEngine.edit(applying: suggestion, before: text)
        return String(text.dropLast(edit.deleteCount)) + edit.insert
    }

    // MARK: - Model

    @Test func formatRoundTrip() throws {
        let model = try model()
        #expect(model.wordCount >= 80_000)
        #expect(model.pairCount >= 240_000)
        for word in ["the", "of", "don't", "zebra", "lol"] {
            let id = try #require(model.id(of: word))
            #expect(model.word(id) == word)
        }
        #expect(model.id(of: "qzxqzx") == nil)
        #expect(model.id(of: "THE") == nil)

        let the = try #require(model.id(of: "the"))
        let th = model.range(ofPrefix: "th")
        #expect(th.contains(the))
        #expect(th.count > 100)
        for id in th { #expect(model.word(id).hasPrefix("th")) }
        // The range is exactly the words with the prefix: the neighbours do not have it.
        if th.lowerBound > 0 { #expect(!model.word(th.lowerBound - 1).hasPrefix("th")) }
        if th.upperBound < model.wordCount { #expect(!model.word(th.upperBound).hasPrefix("th")) }
        #expect(model.range(ofPrefix: "qzxqzx").isEmpty)
        #expect(model.range(ofPrefix: "").count == model.wordCount)

        let ends = Array(model.ids(first: "t", last: "e"))
        #expect(ends.contains(the))
        #expect(ends.allSatisfy { model.word($0).first == "t" && model.word($0).last == "e" })
        #expect(ends == ends.sorted())
        #expect(model.ids(first: "1", last: "e").isEmpty)

        let of = try #require(model.id(of: "of"))
        let logP = try #require(model.pairLogP(of, the))
        #expect(logP < 0 && logP > -3)
        #expect(model.pairLogP(try #require(model.id(of: "zebra")), the) == nil)

        #expect(model.unigram(the) > model.unigram(try #require(model.id(of: "zebra"))))
        #expect(model.isContraction(try #require(model.id(of: "don't"))))
        #expect(!model.isContraction(the))
        #expect(model.next(after: of, limit: 3).contains(the))
        let top = model.completions(prefix: "th", limit: 5)
        #expect(top.count == 5)
        #expect(top.first == the)
        #expect(top.map { model.unigram($0) } == top.map { model.unigram($0) }.sorted(by: >))
    }

    @Test func bundledIsShared() throws {
        #expect(try TypingModel.bundled() === TypingModel.bundled())
    }

    @Test func refusesAFileThatIsNotAModel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notamodel-\(UUID()).mtm")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("MTM1".utf8).write(to: url)
        #expect(throws: TypingModel.LoadError.truncated) { try TypingModel(url: url) }
        try Data(repeating: 0, count: 64).write(to: url)
        #expect(throws: TypingModel.LoadError.badMagic) { try TypingModel(url: url) }
    }

    /// The model must stay a mapped file: if a section were copied into a Swift array it would
    /// count against the keyboard's memory limit. Reflection shows every stored property.
    @Test func holdsNoLargeArrays() throws {
        let model = try model()
        for child in Mirror(reflecting: model).children {
            let mirror = Mirror(reflecting: child.value)
            if mirror.displayStyle == .collection || mirror.displayStyle == .set || mirror.displayStyle == .dictionary {
                #expect(mirror.children.count <= 1000, "\(child.label ?? "?") holds \(mirror.children.count) elements")
            }
            if let data = child.value as? Data {
                // The file itself: megabytes, mapped rather than read.
                #expect(data.count > 1_000_000)
            }
        }
    }

    // MARK: - Suggestions

    @Test func midWordOffersTypedThenCompletions() throws {
        let suggestions = try SuggestionEngine.suggestions(before: "th", model: model())
        #expect(suggestions.count == 3)
        #expect(suggestions[0] == Suggestion(text: "th", kind: .typed))
        // Slot order is left, centre, right: the likeliest completion sits in the centre.
        #expect(suggestions[1] == Suggestion(text: "the", kind: .completion))
        #expect(suggestions.map(\.text).contains("that"))
        #expect(suggestions[1...].allSatisfy { $0.kind == .completion })
    }

    @Test("Explicit and spam words are never volunteered as the next word, though they still complete")
    func neverVolunteered() throws {
        let model = try model()
        for text in ["my dog ", "watch the ", "free ", "hot ", "a video ", "online "] {
            let words = SuggestionEngine.suggestions(before: text, model: model).map { $0.text.lowercased() }
            #expect(words.count == 3)
            #expect(words.allSatisfy { !SuggestionEngine.neverVolunteered.contains($0) }, "\(text): \(words)")
        }
        // Typed, the word is still there to finish.
        #expect(try texts("porn").contains { $0.lowercased().hasPrefix("porn") })
    }

    @Test("Tapping the centre cell again and again does not loop")
    func centreTapsDoNotLoop() throws {
        let model = try model()
        for start in ["The ", "I ", "Please ", "my dog "] {
            var text = start
            for _ in 0..<16 {
                let cells = SuggestionEngine.suggestions(before: text, model: model)
                let centre = try #require(cells.count >= 2 ? cells[1] : cells.first)
                text += centre.text + " "
            }
            let words = SuggestionEngine.recentWords(before: text + "x").dropLast()
            let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
            #expect(Set(pairs).count == pairs.count, "a pair of words repeats in: \(text)")
            #expect(text.lowercased().split(separator: " ").allSatisfy { !SuggestionEngine.neverVolunteered.contains(String($0)) })
        }
    }

    @Test("The words of the sentence so far, oldest first, stopping at a sentence end")
    func recentWords() {
        #expect(SuggestionEngine.recentWords(before: "Hello there. The same time ") == ["the", "same", "time"])
        #expect(SuggestionEngine.recentWords(before: "one\ntwo three") == ["two", "three"])
        #expect(SuggestionEngine.recentWords(before: "") == [])
        let long = (1...20).map { _ in "word" }.joined(separator: " ")
        #expect(SuggestionEngine.recentWords(before: long).count == SuggestionEngine.repeatWindow)
    }

    @Test func nextWordAfterISuggestsAmOrHave() throws {
        let suggestions = try SuggestionEngine.suggestions(before: "I ", model: model())
        #expect(suggestions.count == 3)
        #expect(suggestions.allSatisfy { $0.kind == .next })
        let words = suggestions.map(\.text)
        #expect(words.contains("am") || words.contains("have"))
        #expect(!words.contains("i") && !words.contains("t") && !words.contains("s"))
    }

    @Test func dontCompletesToTheContraction() throws {
        let words = try texts("don")
        #expect(words.first == "don")
        #expect(words.contains("don't"))
    }

    @Test func typedCaseCarriesOverToCompletions() throws {
        #expect(try texts("Th")[1] == "The")
        #expect(try texts("TH")[1] == "THE")
        // "I" is always a capital, whatever was typed before the apostrophe.
        #expect(try texts("i'")[1].hasPrefix("I'"))
    }

    @Test func unknownWordKeepsOnlyTheTypedEntry() throws {
        #expect(try texts("qzxq") == ["qzxq"])
    }

    @Test func sentenceStartsAreCapitalised() throws {
        let start = try texts("")
        #expect(start.count == 3)
        #expect(start[1] == "I")
        #expect(try texts("Fine. ")[1] == "I")
        let afterNewline = try texts("one two\n")
        #expect(afterNewline.allSatisfy { $0.first?.isUppercase == true })
        // Mid-sentence predictions stay lowercase.
        #expect(try texts("I ").allSatisfy { $0.first?.isLowercase == true })
    }

    @Test func noSuggestionsAgainstPunctuationOrDigits() throws {
        #expect(try texts("wait.").isEmpty)
        #expect(try texts("3").isEmpty)
        #expect(try texts("(").isEmpty)
        // After a comma and a space there is no previous word, but predictions still come.
        #expect(try texts("hello, ").count == 3)
    }

    @Test func previousWordShiftsTheRanking() throws {
        // "of th" and "in th" both favour "the"; "I th" favours "think" over the stand-alone
        // frequency winner, which shows the previous word is used.
        let afterI = try texts("I th")
        #expect(afterI.contains("think") || afterI.contains("thought"))
        #expect(try texts("th")[1] == "the")
    }

    @Test func tappingASuggestionReplacesTheWordAndAddsASpace() throws {
        let the = try #require(SuggestionEngine.suggestions(before: "th", model: model()).first { $0.text == "the" })
        #expect(apply(the, to: "th") == "the ")
        #expect(apply(the, to: "so th") == "so the ")
        let next = try #require(SuggestionEngine.suggestions(before: "I ", model: model()).first)
        #expect(apply(next, to: "I ") == "I " + next.text + " ")
        // Tapping the typed word keeps it and adds the space.
        #expect(apply(Suggestion(text: "th", kind: .typed), to: "th") == "th ")
    }

    // MARK: - PendingSpace

    @Test func pendingSpaceIsSwallowedOnce() {
        var pending = PendingSpace()
        let swallowed1 = pending.consumeSpace()
        #expect(!swallowed1)
        pending.noteSuggestionInserted(at: 12.5)
        #expect(pending.isArmed)
        #expect(pending.armedAt == 12.5)
        let swallowed2 = pending.consumeSpace()
        #expect(swallowed2)
        #expect(!pending.isArmed)
        let swallowed3 = pending.consumeSpace()
        #expect(!swallowed3)
    }

    @Test func pendingSpaceIsTakenByClosingMarks() {
        var pending = PendingSpace()
        for mark: Character in [",", ".", "!", "?", ";", ":", ")"] {
            #expect(!pending.takesSpace(before: mark), "not armed")
            pending.noteSuggestionInserted(at: 0)
            #expect(pending.takesSpace(before: mark))
            pending.disarm()
        }
        pending.noteSuggestionInserted(at: 0)
        #expect(!pending.takesSpace(before: "("))
        #expect(!pending.takesSpace(before: "a"))
    }

    @Test func anyOtherKeyDisarmsThePendingSpace() {
        var pending = PendingSpace()
        pending.noteSuggestionInserted(at: 1)
        pending.disarm()
        let swallowed1 = pending.consumeSpace()
        #expect(!swallowed1)
        #expect(!pending.takesSpace(before: "."))
        // Arming again starts over.
        pending.noteSuggestionInserted(at: 2)
        let swallowed2 = pending.consumeSpace()
        #expect(swallowed2)
    }
}
