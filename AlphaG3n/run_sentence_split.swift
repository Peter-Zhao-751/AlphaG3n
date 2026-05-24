// Standalone smoke test for SentenceSplitter (pure NaturalLanguage logic).
//
// Mirrors the repo's run_*.swift convention: compile the REAL source file
// together with this @main entry point and run it.
//
// usage:
//   swiftc SentenceSplitter.swift run_sentence_split.swift \
//       -o /tmp/sentence_split && /tmp/sentence_split

import Foundation

@main
struct SentenceSplitterTest {

    static var failures = 0

    static func expect(_ actual: [String], _ expected: [String], _ name: String) {
        if actual == expected {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)\n      expected \(expected)\n      got      \(actual)")
        }
    }

    static func expectCount(_ actual: [String], _ expected: Int, _ name: String) {
        if actual.count == expected {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)\n      expected \(expected) sentence(s)\n      got      \(actual.count): \(actual)")
        }
    }

    static func main() {
        // 1. Plain two-sentence prose splits on the period, each trimmed.
        expect(
            SentenceSplitter.sentences(in: "It was a dark night. The wind howled."),
            ["It was a dark night.", "The wind howled."],
            "two plain sentences")

        // 2. ? and ! count as sentence terminators too.
        expectCount(
            SentenceSplitter.sentences(in: "Really? Yes! Okay then."),
            3,
            "question + exclamation + statement -> 3")

        // 3. A single sentence stays whole and is NOT drill-in eligible.
        let single = SentenceSplitter.sentences(in: "Just one sentence here.")
        expectCount(single, 1, "single sentence -> 1")
        if SentenceSplitter.hasMultipleSentences(in: "Just one sentence here.") {
            failures += 1
            print("  ✗ single sentence must not report multiple")
        } else {
            print("  ✓ single sentence not flagged as multiple")
        }

        // 4. Blank / whitespace-only input yields nothing.
        expect(SentenceSplitter.sentences(in: "   \n\t  "), [], "whitespace-only -> empty")
        expect(SentenceSplitter.sentences(in: ""), [], "empty string -> empty")

        // 5. Abbreviations must NOT cause a false split ("Dr." stays attached).
        expectCount(
            SentenceSplitter.sentences(in: "Dr. Smith arrived early. He waited inside."),
            2,
            "abbreviation does not over-split")

        // 6. Decimals must NOT cause a false split ("3.14" stays one number).
        expectCount(
            SentenceSplitter.sentences(in: "Pi is about 3.14 in value. That fact helps."),
            2,
            "decimal does not over-split")

        // 7. OCR text often carries newlines between lines of one paragraph;
        //    they shouldn't fabricate extra sentences beyond the real boundaries.
        expectCount(
            SentenceSplitter.sentences(in: "First sentence ends here.\nSecond sentence follows."),
            2,
            "newline between sentences -> 2")

        if failures == 0 {
            print("\nall sentence-split checks passed")
            exit(0)
        } else {
            print("\n\(failures) sentence-split check(s) failed")
            exit(1)
        }
    }
}
