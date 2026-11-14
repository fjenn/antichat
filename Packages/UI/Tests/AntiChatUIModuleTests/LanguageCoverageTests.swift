// LanguageCoverageTests (M1.T09 step 6; AT-008 leg 1): Highlightr highlights ≥ 30 of the named languages, i.e. a
// short sample in each yields more than one token colour.
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct LanguageCoverageTests {
    static let samples: [(String, String)] = [
        ("swift", "import Foundation\nlet x: Int = 42 // answer\nfunc f() -> String { \"hi\" }"),
        ("python", "import os\ndef f(x):\n    return x + 1  # comment\nprint(\"hi\")"),
        ("javascript", "const x = 42; // answer\nfunction f(a) { return `hi ${a}`; }"),
        ("typescript", "interface P { name: string }\nconst x: number = 42;\nexport function f(): void {}"),
        ("java", "public class A {\n  // c\n  public static void main(String[] a) { int x = 1; }\n}"),
        ("kotlin", "fun main() {\n    val x: Int = 42 // c\n    println(\"hi\")\n}"),
        ("c", "#include <stdio.h>\nint main(void) { /* c */ return printf(\"hi\"); }"),
        ("cpp", "#include <vector>\nint main() { std::vector<int> v{1, 2}; return 0; } // c"),
        ("csharp", "using System;\nclass A { static void Main() { var x = 42; Console.WriteLine(\"hi\"); } }"),
        ("go", "package main\nimport \"fmt\"\nfunc main() { x := 42 // c\n fmt.Println(x) }"),
        ("rust", "fn main() {\n    let x: i32 = 42; // c\n    println!(\"{}\", x);\n}"),
        ("ruby", "def f(x)\n  x + 1 # c\nend\nputs \"hi\""),
        ("php", "<?php\nfunction f($x) { return $x + 1; } // c\necho \"hi\";"),
        ("bash", "#!/bin/bash\nfor i in 1 2 3; do echo \"$i\"; done # c"),
        ("zsh", "#!/bin/zsh\nif [[ -n $HOME ]]; then echo \"hi\"; fi # c"),
        ("powershell", "$x = 42 # c\nfunction Get-Answer { param($a) return $a }\nWrite-Host \"hi\""),
        ("sql", "SELECT name, COUNT(*) FROM users WHERE id > 10 GROUP BY name; -- c"),
        ("html", "<!doctype html>\n<html><body class=\"a\"><!-- c --><p>Hi</p></body></html>"),
        ("css", "body { color: #333; margin: 0 auto; } /* c */\n.a:hover { color: red; }"),
        ("scss", "$c: #333;\n.a { color: $c; &:hover { color: red; } } // c"),
        ("json", "{\"name\": \"x\", \"n\": 42, \"ok\": true, \"list\": [1, null]}"),
        ("yaml", "name: x # c\nlist:\n  - 1\n  - true\nnested: {a: \"b\"}"),
        ("toml", "[server]\nport = 8080 # c\nname = \"x\"\nenabled = true"),
        ("xml", "<?xml version=\"1.0\"?>\n<root a=\"1\"><!-- c --><item>x</item></root>"),
        ("markdown", "# Title\n\nSome **bold** and `code`.\n\n- item\n[link](https://x.y)"),
        ("lua", "local x = 42 -- c\nfunction f(a) return a + 1 end\nprint(\"hi\")"),
        ("r", "x <- c(1, 2, 3) # c\nf <- function(a) { a + 1 }\nprint(\"hi\")"),
        ("scala", "object A { def main(a: Array[String]): Unit = { val x = 42 // c\n println(\"hi\") } }"),
        ("haskell", "module Main where\n-- c\nmain :: IO ()\nmain = putStrLn \"hi\""),
        ("dart", "void main() {\n  final x = 42; // c\n  print('hi $x');\n}"),
        ("objectivec", "#import <Foundation/Foundation.h>\n@interface A : NSObject\n@end // c\nNSString *s = @\"hi\";"),
        ("perl", "use strict;\nmy $x = 42; # c\nsub f { return $_[0] + 1 }\nprint \"hi\\n\";"),
        ("elixir", "defmodule A do\n  def f(x), do: x + 1 # c\nend\nIO.puts(\"hi\")"),
        ("dockerfile", "FROM alpine:3.20\n# c\nRUN apk add --no-cache curl\nCMD [\"sh\"]"),
        ("makefile", "CC = cc # c\nall: main.o\n\t$(CC) -o app main.o\n.PHONY: all"),
    ]

    @Test func atLeastThirtyLanguagesHighlighted() async {
        var highlighted: [String] = []
        var plain: [String] = []
        for (lang, code) in Self.samples {
            let colours = await CodeHighlighter.shared.highlight(code, language: lang, dark: false)
                .map(CodeHighlighter.colourCount) ?? 0
            if colours > 1 { highlighted.append(lang) } else { plain.append(lang) }
        }
        print("LanguageCoverageTests: \(highlighted.count)/\(Self.samples.count) highlighted; plain: \(plain)")
        #expect(Self.samples.count == 35)
        #expect(highlighted.count >= 30)
    }

    /// Unknown fence names stay plain (no auto-detection painting prose as code).
    @Test func unknownLanguageStaysPlain() async {
        #expect(await CodeHighlighter.shared.highlight("hello world", language: "no-such-language", dark: false) == nil)
        #expect(await CodeHighlighter.shared.highlight("hello world", language: nil, dark: false) == nil)
    }

    @Test func darkThemeAlsoHighlights() async {
        let colours = await CodeHighlighter.shared.highlight(Self.samples[0].1, language: "swift", dark: true)
            .map(CodeHighlighter.colourCount) ?? 0
        #expect(colours > 1)
    }
}
