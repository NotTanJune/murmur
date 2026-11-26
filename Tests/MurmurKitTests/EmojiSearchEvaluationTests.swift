import Foundation
import Testing
@testable import MurmurKit

/// Measures keyword emoji search against a hand-written set of queries and the emoji a person
/// would accept for each. Each hit is any of them in first place (top 1) or in the first five
/// (top 5). Prints the numbers and the per-query lists; it asserts nothing about them, because
/// the sets are small and the numbers say little about what people type. It also times a search.
/// Skipped unless `MURMUR_EMOJI_EVAL` is set:
///
///     MURMUR_EMOJI_EVAL=1 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter EmojiSearchEvaluation
@Suite(.serialized)
struct EmojiSearchEvaluationTests {
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

    /// Longer, vaguer wording that shares few words with the names and keywords, and was never
    /// used to tune the ranker: the held-out set, and the kind of query keyword search finds hard.
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

    @Test("Keyword search, top 1 and top 5, with timings", .enabled(if: enabled))
    func evaluate() {
        let search = EmojiSearch.standard
        var report = "\nemoji search evaluation: \(Self.queries.count) queries, \(Self.descriptive.count) held out, \(search.entries.count) emoji\n"

        var times: [Double] = []
        for (query, _) in Self.queries + Self.descriptive {
            times.append(seconds { _ = search.search(query) })
        }
        times.sort()
        report += String(format: "per query: median %.2f ms, max %.2f ms (a debug build unless run with -c release)\n",
                         times[times.count / 2] * 1000, times.last! * 1000)

        func line(_ name: String, _ result: Score, of count: Int) -> String {
            "\(name.padding(toLength: 24, withPad: " ", startingAt: 0)) top1 \(result.top1)/\(count) (\(Int((Double(result.top1) / Double(count) * 100).rounded()))%)   top5 \(result.top5)/\(count) (\(Int((Double(result.top5) / Double(count) * 100).rounded()))%)\n"
        }
        let main = score { search.search($0) }
        let held = score(Self.descriptive) { search.search($0) }
        report += line("queries", main, of: Self.queries.count)
        report += line("held-out descriptive", held, of: Self.descriptive.count)
        report += "misses, queries:\n" + main.misses.map { "  \($0)\n" }.joined()
        report += "misses, held out:\n" + held.misses.map { "  \($0)\n" }.joined()
        print(report)
        try? report.write(toFile: ProcessInfo.processInfo.environment["MURMUR_EMOJI_EVAL_OUT"] ?? "/dev/null", atomically: true, encoding: .utf8)
    }
}
