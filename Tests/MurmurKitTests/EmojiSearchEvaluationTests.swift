import Foundation
import Testing
@testable import MurmurKit

#if canImport(NaturalLanguage)

/// Measures emoji search against Apple's real sentence embedding, on the Mac. Slow (it embeds all
/// 1,906 emoji), so it only runs with `MURMUR_EMOJI_EVAL=1`:
///
///     MURMUR_EMOJI_EVAL=1 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter EmojiSearchEvaluation
///
/// Each query has the emoji a person would accept. A hit is any of them in the first place (top 1)
/// or the first five (top 5). The set was written before the blend was tuned, and the tuning
/// only moved the weights below, but the numbers are in-sample for those and say nothing certain
/// about what people type.
@Suite(.serialized)
struct EmojiSearchEvaluationTests {
    /// `MURMUR_EMOJI_EVAL=quick` skips the sweeps over the other embedding texts.
    static let quick = ProcessInfo.processInfo.environment["MURMUR_EMOJI_EVAL"] == "quick"
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_EMOJI_EVAL"] != nil

    static let queries: [(query: String, accept: [String])] = [
        ("crying laughing", ["😂", "🤣"]),
        ("money", ["🤑", "💰", "💵", "💸"]),
        ("facepalm", ["🤦", "🤦‍♂️", "🤦‍♀️"]),
        ("party", ["🥳", "🎉", "🎊"]),
        ("thinking", ["🤔"]),
        ("heart eyes", ["😍"]),
        ("sweating nervous", ["😅", "😰", "😓"]),
        ("spicy", ["🌶️", "🥵"]),
        ("sleepy tired", ["😴", "🥱", "😪", "💤"]),
        ("mind blown", ["🤯"]),
        ("cool sunglasses", ["😎"]),
        ("eyes looking", ["👀"]),
        ("fire hot", ["🔥"]),
        ("pray please thanks", ["🙏"]),
        ("clapping", ["👏"]),
        ("skull dead", ["💀", "☠️"]),
        ("rocket launch", ["🚀"]),
        ("awkward", ["😬", "😅", "🫣"]),
        ("celebrate", ["🎉", "🥳", "🎊", "🍾", "🥂"]),
        ("gross", ["🤢", "🤮"]),
        ("love you", ["🥰", "😍", "❤️", "😘", "🤟"]),
        ("good luck", ["🍀", "🤞"]),
        ("angry", ["😡", "😠", "🤬"]),
        ("sad", ["😢", "😞", "😔", "☹️", "🙁", "😭"]),
        ("birthday", ["🎂", "🎉", "🥳", "🎈"]),
        ("cat", ["🐱", "🐈", "😺"]),
        ("dog", ["🐶", "🐕"]),
        ("pizza", ["🍕"]),
        ("coffee", ["☕"]),
        ("sunny weather", ["☀️", "🌞", "🌤️"]),
        ("raining", ["🌧️", "☔"]),
        ("kiss", ["😘", "💋", "😗", "💏"]),
        ("scared", ["😱", "😨", "😰"]),
        ("laughing", ["😂", "🤣", "😆", "😄", "😀"]),
        ("wink", ["😉"]),
        ("i am so tired", ["😴", "🥱", "😪", "😫", "💤"]),
        ("high five", ["🙌", "🖐️", "✋"]),
        ("dancing", ["💃", "🕺"]),
        ("car", ["🚗"]),
        ("beer", ["🍺", "🍻"]),
        ("feeling sick", ["🤒", "🤢", "🤮", "🤧"]),
        ("hugging", ["🤗", "🫂"]),
        ("thumbs up", ["👍"]),
        ("strong muscle", ["💪"]),
        ("shrug", ["🤷", "🤷‍♂️", "🤷‍♀️"]),
        ("confused", ["😕", "🤔", "😵‍💫"]),
        ("so excited", ["🤩", "🥳", "😆"]),
        ("crying", ["😭", "😢"]),
        ("cute", ["🥰", "🥺", "😊"]),
        ("embarrassed", ["😳", "😅", "🫣", "😬"]),
        ("congratulations", ["🎉", "🥳", "🎊", "👏"]),
    ]

    /// Longer, vaguer wording, written after the blend was tuned and never used to tune it: the
    /// held-out check, and the kind of query the semantic half is for.
    static let descriptive: [(query: String, accept: [String])] = [
        ("awesome job", ["👏", "🙌", "👍", "💪", "🎉"]),
        ("cant stop laughing", ["😂", "🤣", "😆"]),
        ("so embarrassing", ["😳", "😅", "🙈", "🫣", "😬"]),
        ("super hungry", ["🍔", "🍕", "🤤", "🍽️", "🥺"]),
        ("freezing cold", ["🥶", "❄️", "🧊"]),
        ("boiling hot day", ["🥵", "☀️", "🔥", "🌞"]),
        ("i give up", ["🏳️", "🤷", "😩", "😫", "🙄", "😮‍💨"]),
        ("mad at you", ["😡", "😠", "🤬"]),
        ("see you later", ["👋", "🫡"]),
        ("take care", ["🤗", "🫶", "❤️", "🙏"]),
        ("happy dance", ["💃", "🕺", "🥳"]),
        ("feeling lucky", ["🍀", "🤞"]),
        ("my bad", ["🙈", "🤦", "😅", "🙏"]),
        ("sounds great", ["👍", "👌", "🙌"]),
        ("no way", ["😱", "🤯", "😮", "🙅"]),
        ("going to the gym", ["💪", "🏋️"]),
        ("tasty food", ["😋", "🍽️", "🤤"]),
        ("talk on the phone", ["📞", "☎️", "📱"]),
        ("late night", ["🌙", "🌃", "😴"]),
        ("broken heart", ["💔"]),
    ]

    private static func key(_ emoji: String) -> String { emoji.replacingOccurrences(of: "\u{FE0F}", with: "") }

    private struct Score {
        var top1 = 0
        var top5 = 0
        var misses: [String] = []
    }

    private func score(_ queries: [(query: String, accept: [String])] = EmojiSearchEvaluationTests.queries, _ run: (String) -> [String]) -> Score {
        var result = Score()
        for (query, accept) in queries {
            let accepted = Set(accept.map(Self.key))
            let found = run(query).prefix(5).map(Self.key)
            if let first = found.first, accepted.contains(first) { result.top1 += 1 }
            if found.contains(where: accepted.contains) {
                result.top5 += 1
            } else {
                result.misses.append("\(query) -> \(found.joined())")
            }
        }
        return result
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test("Lexical against blended, top 1 and top 5, with timings", .enabled(if: enabled))
    func evaluate() throws {
        let search = EmojiSearch.standard
        let embedder = try #require(NLEmbeddingEmojiEmbedder())
        var report = "\nemoji search evaluation: \(Self.queries.count) queries, \(search.entries.count) emoji, embedder \(embedder.revision), dimension \(embedder.dimension)\n"

        func table(texts: [String]) -> (EmojiVectors, Double) {
            var values: [Float] = []
            let time = seconds {
                for text in texts {
                    let row = EmojiVectors.normalised(embedder.vector(for: text) ?? []) ?? [Float](repeating: 0, count: embedder.dimension)
                    values.append(contentsOf: row)
                }
            }
            return (EmojiVectors(dimension: embedder.dimension, values: values), time)
        }
        let fullTexts = search.entries.map { ([$0.name] + $0.keywords).joined(separator: ", ") }
        let nameTexts = search.entries.map(\.name)
        let fewTexts = search.entries.indices.map { search.embeddingText(at: $0) }
        let (fullTable, fullTime) = table(texts: fullTexts)
        let (nameTable, nameTime) = table(texts: nameTexts)
        let (fewTable, fewTime) = table(texts: fewTexts)
        report += String(format: "embed all emoji, name + keywords: %.2f s (%.2f ms each); name only: %.2f s; shipped text (name + 3 keywords): %.2f s (%.2f ms each)\n", fullTime, fullTime * 1000 / Double(fullTexts.count), nameTime, fewTime, fewTime * 1000 / Double(fewTexts.count))

        // Per query: the embedder's time and the blend's time.
        var embedTimes: [Double] = []
        var blendTimes: [Double] = []
        var queryVectors: [String: [Float]] = [:]
        for (query, _) in Self.queries {
            var vector: [Float]?
            embedTimes.append(seconds { vector = EmojiVectors.normalised(embedder.vector(for: query) ?? []) })
            queryVectors[query] = vector
        }
        for (query, _) in Self.queries {
            blendTimes.append(seconds { _ = search.search(query, queryVector: queryVectors[query], vectors: fewTable) })
        }
        embedTimes.sort()
        blendTimes.sort()
        report += String(format: "per query: embed median %.2f ms, max %.2f ms; blend (lexical + 1,906 cosines) median %.2f ms, max %.2f ms (debug build)\n",
                         embedTimes[embedTimes.count / 2] * 1000, embedTimes.last! * 1000,
                         blendTimes[blendTimes.count / 2] * 1000, blendTimes.last! * 1000)

        func line(_ name: String, _ result: Score) -> String {
            "\(name.padding(toLength: 52, withPad: " ", startingAt: 0)) top1 \(result.top1)/\(Self.queries.count) (\(Int((Double(result.top1) / Double(Self.queries.count) * 100).rounded()))%)   top5 \(result.top5)/\(Self.queries.count) (\(Int((Double(result.top5) / Double(Self.queries.count) * 100).rounded()))%)\n"
        }

        for (query, _) in Self.descriptive { queryVectors[query] = EmojiVectors.normalised(embedder.vector(for: query) ?? []) }
        let lexical = score { search.search($0) }
        report += line("lexical only", lexical)
        for (name, vectors) in [("name + keywords", fullTable), ("name only", nameTable), ("name + 3 keywords", fewTable)] {
            if Self.quick, name != "name + 3 keywords" { continue }
            let semanticOnly = score { query in
                guard let q = queryVectors[query] else { return [] }
                let cosines = vectors.similarities(to: q)
                return cosines.indices.sorted { cosines[$0] > cosines[$1] }.prefix(5).map { search.entries[$0].emoji }
            }
            report += line("semantic only, \(name)", semanticOnly)
            for rerank in [0.0, 0.05] {
                for fill in [0.1, 0.15, 0.3] {
                    for deviations in [1.5, 2.0, 2.5] {
                        var blend = EmojiSearch.Blend()
                        blend.rerankWeight = rerank
                        blend.fillWeight = fill
                        blend.floorDeviations = deviations
                        let result = score { search.search($0, queryVector: queryVectors[$0], vectors: vectors, blend: blend) }
                        let held = score(Self.descriptive) { search.search($0, queryVector: queryVectors[$0], vectors: vectors, blend: blend) }
                        report += line("blend \(name), rerank \(rerank), fill \(fill), floor \(deviations)", result).dropLast() + "   held-out top1 \(held.top1)/20 top5 \(held.top5)/20\n"
                    }
                }
            }
        }
        let shipped = score { search.search($0, queryVector: queryVectors[$0], vectors: fewTable) }
        report += line("SHIPPED default (name + 3 keywords, default blend)", shipped)
        // Held out: wording the sweeps never saw.
        let heldLexical = score(Self.descriptive) { search.search($0) }
        let heldShipped = score(Self.descriptive) { search.search($0, queryVector: queryVectors[$0], vectors: fewTable) }
        func heldLine(_ name: String, _ result: Score) -> String {
            "\(name.padding(toLength: 52, withPad: " ", startingAt: 0)) top1 \(result.top1)/\(Self.descriptive.count)   top5 \(result.top5)/\(Self.descriptive.count)\n"
        }
        report += "held-out descriptive queries (not used for tuning):\n"
        report += heldLine("  lexical only", heldLexical)
        report += heldLine("  shipped blend", heldShipped)
        for (query, accept) in Self.descriptive {
            let accepted = Set(accept.map(Self.key))
            let lex = search.search(query, limit: 5)
            let blended = search.search(query, queryVector: queryVectors[query], vectors: fewTable, limit: 5)
            func mark(_ list: [String]) -> String { (list.first.map { accepted.contains(Self.key($0)) } ?? false) ? "ok " : "-- " }
            report += "  \(query.padding(toLength: 22, withPad: " ", startingAt: 0)) \(mark(lex))\(lex.joined().padding(toLength: 12, withPad: " ", startingAt: 0)) | \(mark(blended))\(blended.joined())\n"
        }
        report += "per query, top 5 (lexical | shipped):\n"
        for (query, accept) in Self.queries {
            let accepted = Set(accept.map(Self.key))
            let lex = search.search(query, limit: 5)
            let blended = search.search(query, queryVector: queryVectors[query], vectors: fewTable, limit: 5)
            func mark(_ list: [String]) -> String { (list.first.map { accepted.contains(Self.key($0)) } ?? false) ? "ok " : "-- " }
            report += "  \(query.padding(toLength: 22, withPad: " ", startingAt: 0)) \(mark(lex))\(lex.joined().padding(toLength: 12, withPad: " ", startingAt: 0)) | \(mark(blended))\(blended.joined())\n"
        }
        report += "misses, lexical only:\n" + lexical.misses.map { "  \($0)\n" }.joined()
        report += "misses, shipped blend:\n" + shipped.misses.map { "  \($0)\n" }.joined()
        print(report)
        try? report.write(toFile: ProcessInfo.processInfo.environment["MURMUR_EMOJI_EVAL_OUT"] ?? "/dev/null", atomically: true, encoding: .utf8)
        #expect(shipped.top5 >= lexical.top5)
        #expect(shipped.top1 >= lexical.top1 - 1)
    }
}

#endif
