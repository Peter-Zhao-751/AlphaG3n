//
//  SentenceSplitter.swift
//  AlphaG3n
//

import Foundation
import NaturalLanguage

/// Splits a text block's transcription into individual sentences for the
/// sentence-by-sentence reading screen.
///
/// Uses NaturalLanguage's on-device sentence tokenizer rather than a naive
/// split on `.?!`, so it doesn't break mid-sentence on abbreviations ("Dr."),
/// decimals ("3.14"), or initialisms ("U.S.A.") — the boundary detection is the
/// "punctuation detection" we want, done properly. Pure, synchronous, and
/// Foundation/NaturalLanguage-only so it can be smoke-tested standalone via
/// `run_sentence_split.swift`.
enum SentenceSplitter {

    /// The trimmed, non-empty sentences in `text`, in reading order. Returns an
    /// empty array for blank input and a single-element array when the text is
    /// just one sentence — callers gate the drill-in on `count >= 2`.
    static func sentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let sentence = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    /// True when `text` holds at least two sentences — the condition for a text
    /// block to become tappable and drill into the reading screen.
    static func hasMultipleSentences(in text: String) -> Bool {
        sentences(in: text).count >= 2
    }
}
