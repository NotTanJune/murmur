import Foundation

/// Turns a raw transcript into text ready to type. Nonisolated and non-throwing so actors and
/// plain structs can conform and callers can hold `any TextFormatter` inside tasks.
protocol TextFormatter: Sendable {
    func format(_ raw: String) async -> String
}

/// Returns the transcript trimmed and otherwise untouched.
struct PassthroughFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The default cleanup and the safety net under the model-backed engines. Pure string work with
/// no state; the stages run in a fixed order and the order is part of the behaviour.
struct RuleBasedFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        Self.clean(raw)
    }

    // MARK: Stages

    private static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return text }

        text = replace(fillerPattern, in: text, with: "")
        text = applySpokenPunctuation(text)
        text = tidyWhitespace(text)
        text = capitaliseSentenceStarts(text)

        if let last = text.last, last.isLetter || last.isNumber {
            text.append(".")
        }
        return text
    }

    // A filler is a whole word: not glued to a preceding word character or ASCII apostrophe, and
    // ending at a word boundary. A comma touching it goes too.
    private static let fillerPattern = makeRegex(
        #"(?<![\p{L}\p{N}\p{M}_'])(?:um|uh|erm|uhm|hmm|mhm)(?![\p{L}\p{N}\p{M}_]),?"#
    )

    private static let spokenCommands: [(NSRegularExpression, String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("open paren", " ("),
        ("close paren", ") "),
    ].map { phrase, output in
        (makeRegex(#"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#),
         NSRegularExpression.escapedTemplate(for: output))
    }

    private static let spaceRun = makeRegex(#"[ \t]+"#, caseInsensitive: false)
    private static let spaceBeforePunctuation = makeRegex(#" (?=[,.!?;:])"#, caseInsensitive: false)
    private static let newlineRun = makeRegex(#"\n{3,}"#, caseInsensitive: false)

    private static func applySpokenPunctuation(_ text: String) -> String {
        spokenCommands.reduce(text) { partial, command in
            let range = NSRange(partial.startIndex..., in: partial)
            return command.0.stringByReplacingMatches(in: partial, range: range, withTemplate: command.1)
        }
    }

    private static func tidyWhitespace(_ text: String) -> String {
        var out = replace(spaceRun, in: text, with: " ")
        out = replace(spaceBeforePunctuation, in: out, with: "")
        out = replace(newlineRun, in: out, with: "\n\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Appends the uppercased string rather than a single Character: some letters expand when
    // uppercased ("ß" to "SS") and a lone Character cannot hold that.
    private static func capitaliseSentenceStarts(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var atStart = true
        for ch in text {
            if atStart, ch.isLetter {
                out += String(ch).uppercased()
                atStart = false
            } else {
                out.append(ch)
                if ch == "." || ch == "!" || ch == "?" || ch.isNewline { atStart = true }
            }
        }
        return out
    }

    // MARK: Regex helpers

    private static func makeRegex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        // The patterns are constants; a failure here is a programming error caught by any test run.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
