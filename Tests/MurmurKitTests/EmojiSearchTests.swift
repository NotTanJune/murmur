import Foundation
import Testing
@testable import MurmurKit

struct EmojiSearchTests {
    private let search = EmojiSearch.standard

    private func top(_ query: String, _ count: Int = 5) -> [String] {
        Array(search.search(query, limit: count))
    }

    @Test("The table has every catalogue emoji, in catalogue order")
    func tableMatchesCatalogue() {
        let catalogue = EmojiCatalog.categories.flatMap(\.emoji)
        #expect(search.entries.map(\.emoji) == catalogue)
        #expect(search.entries.allSatisfy { !$0.name.isEmpty })
    }

    @Test("Words are lowercased, split at punctuation and stemmed")
    func words() {
        #expect(EmojiSearch.words("Crying, LAUGHING!") == ["cry", "laugh"])
        #expect(EmojiSearch.words("don't") == ["dont"])
        #expect(EmojiSearch.words("hearts-eyes") == ["heart", "eye"])
        #expect(EmojiSearch.words("running") == ["run"])
        #expect(EmojiSearch.words("parties") == ["party"])
        #expect(EmojiSearch.words("kiss") == ["kiss"])
        #expect(EmojiSearch.queryWords("a thing of joy") == ["thing", "joy"])
        #expect(EmojiSearch.queryWords("the") == ["the"])
        #expect(EmojiSearch.queryWords("i am so tired") == EmojiSearch.words("tired"))
    }

    @Test("A name typed exactly comes first")
    func exactName() {
        #expect(top("fire").first == "🔥")
        #expect(top("thumbs up").first == "👍")
        #expect(top("rocket").first == "🚀")
        #expect(top("face with tears of joy").first == "😂")
    }

    @Test("Keywords find an emoji the name does not")
    func keywords() {
        #expect(top("facepalm").contains("🤦"))
        #expect(top("lol").contains("😂"))
    }

    @Test("A plural, an -ing form and a case difference find the same emoji")
    func stemming() {
        #expect(top("Hearts", 8).contains("❤️"))
        #expect(top("crying", 8).contains("😭"))
        #expect(top("CRYING", 8) == top("crying", 8))
    }

    @Test("The last word may be a prefix, an earlier one may not")
    func prefix() {
        #expect(top("sunglas").contains("😎"))
        // "sungl" is not a whole word, so with another word after it nothing matches by it.
        #expect(search.lexicalHits("sungl zzzz").isEmpty)
    }

    @Test("An emoji that matches more of the words ranks above one that matches fewer")
    func multiWord() {
        let hits = search.lexicalHits("heart eyes").map { search.entries[$0.index].emoji }
        #expect(hits.prefix(3).contains("😍"))
        let both = hits.firstIndex(of: "😍")!
        let one = hits.firstIndex(of: "❤️")!
        #expect(both < one)
    }

    @Test("Nothing, or only punctuation, finds nothing")
    func emptyQueries() {
        #expect(search.search("").isEmpty)
        #expect(search.search("   ").isEmpty)
        #expect(search.search("!?").isEmpty)
        #expect(search.search("qzxqzxqzx").isEmpty)
    }

    @Test("Scores are between 0 and 1 and the whole name scores highest")
    func scores() {
        let hits = search.lexicalHits("fire")
        #expect(hits.allSatisfy { $0.score > 0 && $0.score <= 1 })
        #expect(search.entries[hits[0].index].emoji == "🔥")
        #expect(hits[0].score > hits[1].score)
    }

    @Test("Common emoji win a tie between equal matches")
    func popularTies() {
        #expect(top("heart").first == "❤️")
        #expect(top("lol", 3).contains("😂"))
        #expect(top("car").contains("🚗"))
    }

    @Test("Every emoji of the popularity list is in the catalogue")
    func popularListIsCatalogue() {
        let catalogue = Set(search.entries.map(\.emoji))
        for emoji in EmojiSearch.popular { #expect(catalogue.contains(emoji), "\(emoji)") }
        #expect(Set(EmojiSearch.popular).count == EmojiSearch.popular.count)
    }

    @Test("The limit applies")
    func limit() {
        #expect(search.search("face", limit: 7).count == 7)
    }
}
