//
//  HTMLTextExtractor.swift
//  AlphaG3n
//
//  Turns a fetched HTML page into plain reading text for summarization. Pure
//  Foundation string work — no WebKit, no main-thread requirement — so it runs
//  on the background fetch task and is smoke-tested standalone via
//  run_html_extract.swift.
//
//  Deliberately lightweight: it strips markup well enough to feed a language
//  model a readable approximation of the page, not to faithfully reconstruct
//  the DOM. Script/style blocks are dropped wholesale, every remaining tag
//  becomes a separator, common entities are decoded, and whitespace is
//  collapsed.
//

import Foundation

enum HTMLTextExtractor {

    /// Plain, collapsed reading text extracted from `html`, clamped to
    /// `maxChars` characters (0 disables the clamp). Returns "" for markup that
    /// carries no text.
    static func plainText(fromHTML html: String, maxChars: Int = 120_000) -> String {
        var s = html

        // 1. Drop <script>/<style> elements *with their contents* — their text
        //    is code, not prose, and would otherwise survive tag-stripping.
        s = removingElement("script", in: s)
        s = removingElement("style", in: s)

        // 2. Drop HTML comments.
        s = replacingRegex("<!--[\\s\\S]*?-->", in: s, with: " ")

        // 3. Every remaining tag becomes a space so adjacent blocks
        //    (</div><div>) don't fuse neighbouring words.
        s = replacingRegex("<[^>]+>", in: s, with: " ")

        // 4. Decode the entities common in body text.
        s = decodingEntities(s)

        // 5. Collapse every run of whitespace (newlines/tabs included) to one
        //    space and trim the ends.
        s = replacingRegex("\\s+", in: s, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if maxChars > 0, s.count > maxChars {
            s = String(s.prefix(maxChars))
        }
        return s
    }

    /// Removes `<tag …>…</tag>` (and its contents), case-insensitively and
    /// across newlines. `\b` after the tag name keeps `<scriptx>` from matching.
    private static func removingElement(_ tag: String, in s: String) -> String {
        replacingRegex("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", in: s, with: " ",
                       options: [.regularExpression, .caseInsensitive])
    }

    /// Decodes the handful of entities that actually show up in readable text.
    /// `&amp;` is decoded LAST so a literal "&amp;lt;" doesn't collapse into "<".
    private static func decodingEntities(_ s: String) -> String {
        var out = s

        // Numeric: &#65; (decimal) and &#x41; (hex).
        out = mappingMatches(of: "&#([0-9]+);", in: out) { digits in
            UInt32(digits).flatMap(Unicode.Scalar.init).map(String.init)
        }
        out = mappingMatches(of: "&#[xX]([0-9A-Fa-f]+);", in: out) { hex in
            UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
        }

        // Named — ampersand intentionally resolved last.
        let named: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "),
            ("&amp;", "&"),
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }

    // MARK: - Regex helpers

    private static func replacingRegex(
        _ pattern: String,
        in s: String,
        with replacement: String,
        options: String.CompareOptions = [.regularExpression]
    ) -> String {
        s.replacingOccurrences(of: pattern, with: replacement, options: options)
    }

    /// Replaces every match of `pattern` (one capture group) with the result of
    /// `transform` applied to that group; matches `transform` returns nil for
    /// are left untouched. Used for numeric-entity decoding, which needs the
    /// captured digits rather than a fixed replacement string.
    private static func mappingMatches(
        of pattern: String,
        in s: String,
        transform: (String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let full = NSRange(s.startIndex..., in: s)
        var result = s
        // Replace from the back so earlier ranges stay valid as we mutate.
        for match in regex.matches(in: s, range: full).reversed() {
            guard match.numberOfRanges >= 2,
                  let whole = Range(match.range, in: result),
                  let group = Range(match.range(at: 1), in: result),
                  let replacement = transform(String(result[group]))
            else { continue }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }
}
