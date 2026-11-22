import Foundation
import Testing
@testable import MurmurKit

/// Cases come from Bark's raw output in the run log (2026-10-27 to 2026-11-08).
struct TranscriptRepairTests {
    @Test("A period Bark wrote at a pause, with the next word left lowercase, is dropped", arguments: [
        ("I know that we had. recognition of numbers", "I know that we had recognition of numbers"),
        ("metrics to keep. in mind? How", "metrics to keep in mind? How"),
        ("and wherever there. are unrecognizable characters", "and wherever there are unrecognizable characters"),
        ("favicon for this. website, so that", "favicon for this website, so that"),
    ])
    func pausePeriodDropped(input: String, output: String) {
        #expect(TranscriptRepair.dropPausePeriods(input) == output)
    }

    @Test("Real sentence ends, spelled letters, ellipses and abbreviations keep their periods", arguments: [
        "we need to look into this. Then it also repeats",
        "our light l. l. m. instance.",
        "embedded. The c. s. v. s",
        "wait... what was that",
        "see e.g. the notes",
        "the parts required, etc. and then",
        "apples vs. oranges here",
        "it is 3.5 inches wide",
        "end of sentence. i think",
    ])
    func realPeriodsKept(text: String) {
        #expect(TranscriptRepair.dropPausePeriods(text) == text)
    }

    @Test("Spoken numbers of ten and above, and every multi-word number, become digits", arguments: [
        ("six thousand", "6,000"),
        ("one thousand fifty nine", "1,059"),
        ("One thousand and fifty-nine.", "1,059."),
        ("slide number twenty two, the", "slide number 22, the"),
        ("forty-eight gigabytes", "48 gigabytes"),
        ("a thirty minute call", "a 30 minute call"),
        ("P fifty latency", "P 50 latency"),
        ("a hundred percent", "100 percent"),
        ("root cost hundred percent", "root cost 100 percent"),
        ("three million users", "3,000,000 users"),
        ("sixteen to twenty are quite", "16 to 20 are quite"),
    ])
    func numeralsWritten(input: String, output: String) {
        #expect(TranscriptRepair.writeNumerals(input) == output)
    }

    @Test("Decimals, years and possessives", arguments: [
        ("Bark three point zero", "Bark 3.0"),
        ("Claude Opus five point five.", "Claude Opus 5.5."),
        ("Fourth August twenty twenty-six. So", "Fourth August 2026. So"),
        ("a ten eighty T", "a 1080 T"),
        ("slide twenty four's content", "slide 24's content"),
    ])
    func decimalsYearsPossessives(input: String, output: String) {
        #expect(TranscriptRepair.writeNumerals(input) == output)
    }

    @Test("Single words under ten stay words, unless they range with a number that converted", arguments: [
        ("one of them", "one of them"),
        ("two slides", "two slides"),
        ("number one priority", "number one priority"),
        ("We had six GPUs", "We had six GPUs"),
        ("three or four", "three or four"),
        ("one by one", "one by one"),
        ("six point. Next", "six point. Next"),
        ("slides six to eleven", "slides 6 to 11"),
        ("ten to fifteen minutes", "10 to 15 minutes"),
        ("twenty-second floor", "twenty-second floor"),
    ])
    func smallNumbersStayWords(input: String, output: String) {
        #expect(TranscriptRepair.writeNumerals(input) == output)
    }

    @Test("The rule pass drops pause periods and writes numerals before it capitalises")
    func rulePassAppliesBoth() async {
        let text = "I know that we had. recognition of six thousand items"
        let out = await RuleBasedFormatter().format(text)
        #expect(out == "I know that we had recognition of 6,000 items.")
    }

    @Test("Letters Bark spelled out join into one uppercase word", arguments: [
        ("point their m. c. p. at their oracle", "point their MCP at their oracle"),
        ("serve our light l. l. m. instance.", "serve our light LLM instance."),
        ("it was a P O C, but it was", "it was a POC, but it was"),
        ("a student of N T U?", "a student of NTU?"),
        ("the next bus N U s app that we", "the next bus NUS app that we"),
        ("used as an A. P. I.", "used as an API."),
        ("a proper p. d. f. The left hand", "a proper PDF. The left hand"),
        ("refinements to this P P T. The code base", "refinements to this PPT. The code base"),
        ("regarding m. c. p. s. I had also worked", "regarding MCPs. I had also worked"),
        ("What about c. s. v. s? What about Excel", "What about CSVs? What about Excel"),
        ("contracts and s. l. a. s are part of", "contracts and SLAs are part of"),
        ("had set up a c. i. c. d. pre commit check.", "had set up a CICD pre commit check."),
        ("a development environment, a U A T or staging", "a development environment, a UAT or staging"),
        ("is wrong in x y z and x y", "is wrong in XYZ and XY"),
        ("very close to a b c that is there", "very close to ABC that is there"),
        ("behind face I d or passcode", "behind face ID or passcode"),
        ("two R T X ten eighty T I, one R T", "two RTX ten eighty TI, one RT"),
        ("to use the m. L. X language model", "to use the MLX language model"),
        ("Explicit K V cash planning", "Explicit KV cash planning"),
        ("N. u. s.", "NUS."),
        ("it runs on a. w. s. today", "it runs on AWS today"),
    ])
    func spelledLettersJoined(input: String, output: String) {
        #expect(TranscriptRepair.joinSpelledLetters(input) == output)
    }

    @Test("Single letters that are words, lone letters and abbreviations are left alone", arguments: [
        "Am I a fool for trying",
        "option A I think is better",
        "this is a B test of plan",
        "and machine B, right? There",
        "that is, i. e. the second one",
        "see e. g. the notes",
        "I think X Core is fine",
        "the P ninety nine latency",
        "it is 3.5 inches wide",
        "",
    ])
    func wordsNotJoined(text: String) {
        #expect(TranscriptRepair.joinSpelledLetters(text) == text)
    }

    @Test("The rule pass joins letters before it capitalises, so no word after one is raised")
    func rulePassJoinsLetters() async {
        let typed = await RuleBasedFormatter().format("customers point their m. c. p. at their oracle or s. q. l. server")
        #expect(typed == "Customers point their MCP at their oracle or SQL server.")
    }
}
