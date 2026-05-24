// Standalone smoke test for HTMLTextExtractor (pure Foundation string logic).
//
// Mirrors the repo's run_*.swift convention: compile the REAL source file
// together with this @main entry point and run it.
//
// usage:
//   swiftc HTMLTextExtractor.swift run_html_extract.swift \
//       -o /tmp/html_extract && /tmp/html_extract

import Foundation

@main
struct HTMLTextExtractorTest {

    static var failures = 0

    static func expect(_ actual: String, _ expected: String, _ name: String) {
        if actual == expected {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)\n      expected \(quoted(expected))\n      got      \(quoted(actual))")
        }
    }

    static func quoted(_ s: String) -> String { "\"\(s)\"" }

    static func main() {
        print("HTMLTextExtractor smoke test")

        // Tags are dropped; surrounding text survives.
        expect(HTMLTextExtractor.plainText(fromHTML: "<p>Hello <b>world</b></p>"),
               "Hello world", "strips inline tags")

        // <script> and its contents are removed entirely (incl. attributes / case).
        expect(HTMLTextExtractor.plainText(fromHTML: "<p>Hi</p><SCRIPT src=\"x\">var x=1; alert('no')</SCRIPT>"),
               "Hi", "removes script block")

        // <style> and its contents are removed entirely.
        expect(HTMLTextExtractor.plainText(fromHTML: "<style>.a{color:red}</style><p>Body</p>"),
               "Body", "removes style block")

        // HTML comments are removed.
        expect(HTMLTextExtractor.plainText(fromHTML: "<p>a<!-- hidden -->b</p>"),
               "a b", "removes comments")

        // Adjacent block tags don't fuse neighbouring words.
        expect(HTMLTextExtractor.plainText(fromHTML: "<div>one</div><div>two</div>"),
               "one two", "tags become separators")

        // Common named entities decode.
        expect(HTMLTextExtractor.plainText(fromHTML: "a &amp; b"), "a & b", "decodes &amp;")
        expect(HTMLTextExtractor.plainText(fromHTML: "x &lt; y &gt; z"), "x < y > z", "decodes &lt; &gt;")
        expect(HTMLTextExtractor.plainText(fromHTML: "&quot;hi&quot;"), "\"hi\"", "decodes &quot;")
        expect(HTMLTextExtractor.plainText(fromHTML: "it&#39;s a&nbsp;b"), "it's a b", "decodes &#39; and &nbsp;")

        // Numeric entities (decimal + hex) decode.
        expect(HTMLTextExtractor.plainText(fromHTML: "&#65;&#x42;"), "AB", "decodes numeric entities")

        // Runs of whitespace (incl. newlines / tabs) collapse to single spaces.
        expect(HTMLTextExtractor.plainText(fromHTML: "<p>Hello\n\n   world\t!</p>"),
               "Hello world !", "collapses whitespace")

        // Empty / whitespace-only input yields empty string.
        expect(HTMLTextExtractor.plainText(fromHTML: "   \n\t "), "", "blank input → empty")

        // maxChars clamps the result.
        let long = "<p>" + String(repeating: "a", count: 100) + "</p>"
        expect(HTMLTextExtractor.plainText(fromHTML: long, maxChars: 10),
               String(repeating: "a", count: 10), "clamps to maxChars")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
