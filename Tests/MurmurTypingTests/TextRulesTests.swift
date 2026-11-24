import Testing

@testable import MurmurTyping

@Suite struct TextRulesTests {
    @Test("Auto-shift in sentence mode: field start, after . ! ? and a space, after a newline")
    func autoShiftSentences() {
        func shifted(_ s: String) -> Bool { TextRules.autoShift(before: s, autocapitalization: .sentences) }
        #expect(shifted(""))
        #expect(shifted("Hello. "))
        #expect(shifted("Really? "))
        #expect(shifted("Stop!  "))
        #expect(shifted("Hi\n"))
        #expect(shifted("He said \"go.\" "))
        #expect(!shifted("Hello."))
        #expect(!shifted("hello "))
        #expect(!shifted("Hello, "))
        #expect(!shifted("Hello"))
    }

    @Test("Auto-shift per word, always, never")
    func autoShiftOtherModes() {
        #expect(TextRules.autoShift(before: "", autocapitalization: .words))
        #expect(TextRules.autoShift(before: "one ", autocapitalization: .words))
        #expect(!TextRules.autoShift(before: "one", autocapitalization: .words))
        #expect(TextRules.autoShift(before: "abc", autocapitalization: .allCharacters))
        #expect(!TextRules.autoShift(before: "", autocapitalization: .none))
        #expect(!TextRules.autoShift(before: "Hello. ", autocapitalization: .none))
    }

    @Test("Double space within 0.6 s after a letter replaces the space with a period and turns shift on")
    func doubleSpace() {
        let effects = TextRules.doubleSpacePeriod(before: "hello ", lastSpaceTime: 10, now: 10.5)
        #expect(effects == [.deleteBackward(count: 1), .insert(". ", tap: nil), .setShift(.on)])
        #expect(TextRules.doubleSpacePeriod(before: "route 66 ", lastSpaceTime: 1, now: 1.6) != nil)
    }

    @Test("Double space does not apply when slow, first, after punctuation or after another space")
    func doubleSpaceDoesNotApply() {
        #expect(TextRules.doubleSpacePeriod(before: "hello ", lastSpaceTime: 10, now: 10.7) == nil)
        #expect(TextRules.doubleSpacePeriod(before: "hello ", lastSpaceTime: nil, now: 10) == nil)
        #expect(TextRules.doubleSpacePeriod(before: "hello", lastSpaceTime: 10, now: 10.2) == nil)
        #expect(TextRules.doubleSpacePeriod(before: "hello. ", lastSpaceTime: 10, now: 10.2) == nil)
        #expect(TextRules.doubleSpacePeriod(before: "hello  ", lastSpaceTime: 10, now: 10.2) == nil)
        #expect(TextRules.doubleSpacePeriod(before: " ", lastSpaceTime: 10, now: 10.2) == nil)
    }

    @Test("Smart quotes open at the start, after a space, bracket or opening quote, and close elsewhere")
    func smartQuotes() {
        #expect(TextRules.smartQuote("\"", before: "", enabled: true) == "“")
        #expect(TextRules.smartQuote("\"", before: "say ", enabled: true) == "“")
        #expect(TextRules.smartQuote("\"", before: "(", enabled: true) == "“")
        #expect(TextRules.smartQuote("\"", before: "“", enabled: true) == "“")
        #expect(TextRules.smartQuote("\"", before: "go", enabled: true) == "”")
        #expect(TextRules.smartQuote("'", before: "", enabled: true) == "‘")
        #expect(TextRules.smartQuote("'", before: "“", enabled: true) == "‘")
        #expect(TextRules.smartQuote("'", before: "don", enabled: true) == "’")
        #expect(TextRules.smartQuote("'", before: "x\n", enabled: true) == "‘")
    }

    @Test("Smart quotes off, or any other mark, comes back unchanged")
    func smartQuotesOff() {
        #expect(TextRules.smartQuote("\"", before: "", enabled: false) == "\"")
        #expect(TextRules.smartQuote("'", before: "don", enabled: false) == "'")
        #expect(TextRules.smartQuote("a", before: "", enabled: true) == "a")
    }

    @Test("Two hyphens become an em dash; one hyphen, or the setting off, does not")
    func smartDash() {
        #expect(
            TextRules.smartDash(before: "wait-", enabled: true)
                == [.deleteBackward(count: 1), .insert("\u{2014}", tap: nil)])
        #expect(TextRules.smartDash(before: "wait", enabled: true) == nil)
        #expect(TextRules.smartDash(before: "wait-", enabled: false) == nil)
        #expect(TextRules.smartDash(before: "", enabled: true) == nil)
    }

    @Test("A lone i becomes I before a space or punctuation, including an apostrophe")
    func standaloneI() {
        let fix: [TypingEffect] = [.deleteBackward(count: 1), .insert("I", tap: nil)]
        #expect(TextRules.standaloneI(before: "i", typed: " ") == fix)
        #expect(TextRules.standaloneI(before: "so i", typed: " ") == fix)
        #expect(TextRules.standaloneI(before: "so i", typed: "'") == fix)
        #expect(TextRules.standaloneI(before: "did i", typed: "?") == fix)
        #expect(TextRules.standaloneI(before: "(i", typed: ")") == fix)
    }

    @Test("A lone i stays when it ends a longer word or the next key is a letter")
    func standaloneINot() {
        #expect(TextRules.standaloneI(before: "hi", typed: " ") == nil)
        #expect(TextRules.standaloneI(before: "pi", typed: ".") == nil)
        #expect(TextRules.standaloneI(before: "i", typed: "m") == nil)
        #expect(TextRules.standaloneI(before: "so I", typed: " ") == nil)
        #expect(TextRules.standaloneI(before: "", typed: " ") == nil)
        #expect(TextRules.standaloneI(before: "x-i", typed: " ") == nil)
    }
}
