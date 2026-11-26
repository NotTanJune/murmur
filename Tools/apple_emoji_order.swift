// Writes the order of the emoji picker on this Mac, one line per section: the section id, a tab,
// then the emoji separated by single spaces. Tools/gen_emoji.py reads it.
//
//     swift Tools/apple_emoji_order.swift Tools/apple-emoji-order.txt
//
// It reads the lists at run time from the system's EmojiFoundation framework. Only the resulting
// list of public Unicode sequences is committed; nothing from the framework ships in the app.
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: apple_emoji_order.swift <out.txt>\n".utf8))
    exit(2)
}
let framework = "/System/Library/PrivateFrameworks/EmojiFoundation.framework/Versions/A/EmojiFoundation"
guard dlopen(framework, RTLD_NOW) != nil else {
    FileHandle.standardError.write(Data("cannot load \(framework)\n".utf8))
    exit(1)
}
guard let category = NSClassFromString("EMFEmojiCategory") as? NSObject.Type else {
    FileHandle.standardError.write(Data("EMFEmojiCategory not found\n".utf8))
    exit(1)
}

let sections: [(id: String, selector: String)] = [
    ("smileys", "PeopleEmoji"),
    ("nature", "NatureEmoji"),
    ("food", "FoodAndDrinkEmoji"),
    ("activity", "ActivityEmoji"),
    ("travel", "TravelAndPlacesEmoji"),
    ("objects", "ObjectsEmoji"),
    ("symbols", "SymbolsEmoji"),
    ("flags", "computeEmojiFlagsSortedByLanguage"),
]

var out = ""
var failed = false
for (id, name) in sections {
    let selector = NSSelectorFromString(name)
    guard category.responds(to: selector),
          let result = category.perform(selector)?.takeUnretainedValue() as? [String],
          !result.isEmpty else {
        FileHandle.standardError.write(Data("empty or missing list: \(id) (\(name))\n".utf8))
        failed = true
        continue
    }
    out += "\(id)\t\(result.joined(separator: " "))\n"
    print("\(id): \(result.count)")
}
if failed { exit(1) }
do { try out.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8) } catch {
    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
    exit(1)
}
