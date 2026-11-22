import Foundation
import Testing
@testable import MurmurKit

struct CleanupTests {
    @Test("Each profile sends a control line from S1-mini's trained set, exactly")
    func controlLines() {
        #expect(CleanupProfile.general.controlLine == "[Styling: semi-formal] [Structure: prose] [Context: general]")
        #expect(CleanupProfile.email.controlLine == "[Styling: semi-formal] [Structure: prose] [Context: email]")
        #expect(CleanupProfile.message.controlLine == "[Styling: semi-casual] [Structure: prose] [Context: general]")
        #expect(CleanupProfile.notes.controlLine == "[Styling: semi-formal] [Structure: lists] [Context: general]")
        #expect(Set(CleanupProfile.allCases.map(\.controlLine)).count == CleanupProfile.allCases.count)
    }

    /// Inputs and outputs recorded from the 4-bit model on an M2 during the benchmark.
    @Test("The guard accepts what S1-mini actually produced", arguments: [
        ("So I need to send the report by Friday. No wait, make that Thursday, and copy Priya on it.",
         "So I need to send the report by Thursday, and copy Priya on it."),
        ("The invoice came to twenty three thousand four hundred and fifty dollars and it's due on March third twenty twenty seven.",
         "The invoice came to $23,450 and it's due on March 3rd, 2027."),
        ("Hey, can you grab some milk on the way home? I'm gonna be like twenty minutes late.",
         "Hey, can you grab some milk on the way home? I'm going to be like 20 minutes late."),
        ("So for the trip we need to pack sunscreen and then also a first aid kit and chargers for everything and you know the passports.",
         "So for the trip we need to pack:\n- Sunscreen\n- A first aid kit\n- Chargers for everything\n- The passports"),
        ("Hey Sarah, just wanted to follow up on the proposal from last week. I think the numbers look good, but can you send me the updated budget by end of week? Also, I mean, let's set up a call on Tuesday, actually Wednesday works better for me. Thanks, John.",
         "Hey Sarah,\n\nJust wanted to follow up on the proposal from last week. I think the numbers look good, but can you send me the updated budget by end of week? Also, let's set up a call on Wednesday, which works better for me.\n\nThanks,\nJohn"),
        ("What is the capital of France?", "What is the capital of France?"),
        ("twenty three thousand four hundred and fifty", "23,450"),
    ])
    func guardAcceptsS1Mini(input: String, output: String) {
        #expect(FoundationModelFormatter.isPlausibleCleanup(original: input, cleaned: output, writesNumerals: true))
    }

    @Test("Numerals don't open a hole for answers")
    func guardStillRejectsAnswers() {
        #expect(!FoundationModelFormatter.isPlausibleCleanup(
            original: "What is the capital of France?", cleaned: "The capital of France is Paris.", writesNumerals: true))
        #expect(!FoundationModelFormatter.isPlausibleCleanup(
            original: "how many moons does mars have", cleaned: "Mars has 2 moons, Phobos and Deimos.", writesNumerals: true))
        // The Apple Intelligence path is unchanged: numerals still count as invented there.
        #expect(!FoundationModelFormatter.isPlausibleCleanup(
            original: "twenty three dollars", cleaned: "$23", writesNumerals: false))
    }
}
