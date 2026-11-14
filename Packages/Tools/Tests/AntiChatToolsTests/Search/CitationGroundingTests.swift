// AT-250 c2 attempt 2: the deterministic grounding check of cited sentences (numbers, months, names vs the passage).
@testable import AntiChatTools
import Testing

@Suite struct CitationGroundingTests {
    let ev = [1: "The release is due no later than March 2027. Version 4.2 is the latest, with 1,250 users in Lisbon.",
              2: "Snippet: Ana Costa said the budget is 3 million euros."]

    @Test func supportedSentencesKeepTheirMarkers() {
        let t = "Version 4.2 is the latest [1]. It has 1250 users in Lisbon [1]. Ana Costa put the budget at three million [2]."
        let r = CitationGrounding.apply(t, evidence: ev)
        #expect(r.text == t && r.checked == 3 && r.uncited == 0)
    }

    @Test func wrongNumberMonthOrNameLosesTheMarker() {
        let t = "The release is due in April 2027 [1]. Version 4.3 is the latest [1]. It is based in Porto [1]. Users: 1,250 [1]."
        let r = CitationGrounding.apply(t, evidence: ev)
        #expect(r.uncited == 3, "\(r.missing)")
        #expect(r.text == "The release is due in April 2027. Version 4.3 is the latest. It is based in Porto. Users: 1,250 [1].")
        #expect(r.missing.flatMap { $0 }.contains("april") && r.missing.flatMap { $0 }.contains("4.3") && r.missing.flatMap { $0 }.contains("Porto"))
    }

    /// M7.T15 (R-241 audit): brackets in code are never treated as markers, and a removed marker never joins lines;
    /// apart from failed markers the answer is byte-identical.
    @Test func codeIsNeverTouchedAndLinesNeverJoin() {
        let t = "Use `arr[1]` here.\n\n```\nx = [1, 2]\nprint(x[1])\n```\nThe release is due in April 2027\n[1] and more."
        let r = CitationGrounding.apply(t, evidence: ev)
        #expect(r.checked == 1 && r.uncited == 1)
        #expect(r.text == "Use `arr[1]` here.\n\n```\nx = [1, 2]\nprint(x[1])\n```\nThe release is due in April 2027\n and more.")
    }

    @Test func multiSourceMarkersUseTheUnionAndUnknownSourcesAreLeftAlone() {
        let r = CitationGrounding.apply("Ana Costa works in Lisbon [1,2]. Something [9].", evidence: ev)
        #expect(r.uncited == 0 && r.checked == 1 && r.text.contains("[9]"))
    }

    /// Attempt 5 (A-M7-T03c): a recency claim needs a recency word in the passage; a release stage must match.
    @Test func recencyAndStageNeedThePassage() {
        let ev = [1: "Blender 5.1.2 was released on May 19, 2026, fixing 40 bugs.",
                  2: "PostgreSQL 19 RC 1 (release candidate) is available. The upcoming conference opens on 3 June.",
                  3: "Firefox 159.0.1 is the latest version."]
        let t = "The most recent release of Blender is 5.1.2 [1]. Blender 5.1.2 was released on May 19, 2026 [1]. "
            + "PostgreSQL 19 is available in beta [2]. PostgreSQL 19 release candidate 1 is available [2]. "
            + "The next conference opens on 3 June [2]. The current Firefox version is 159.0.1 [3]."
        let r = CitationGrounding.apply(t, evidence: ev)
        #expect(r.uncited == 2, "\(r.missing)")
        #expect(r.missing.flatMap { $0 }.contains("recency") && r.missing.flatMap { $0 }.contains("beta"))
        #expect(r.text.hasPrefix("The most recent release of Blender is 5.1.2. Blender 5.1.2 was released on May 19, 2026 [1]."))
        #expect(r.text.contains("in beta. PostgreSQL") && r.text.contains("is available [2]") && r.text.contains("3 June [2]")
                && r.text.hasSuffix("159.0.1 [3]."))
    }

    /// Attempt 5: a scope/strength qualifier must be stated near the claim's anchors in the passage.
    @Test func qualifiersNeedThePassage() {
        let ev = [1: "X-rays are used in medical radiography to image bones. They are also used in airport security.",
                  2: "Penicillin was the first antibiotic discovered, by Alexander Fleming in 1928."]
        let t = "The main use of X-rays is medical radiography to image bones [1]. "
            + "Penicillin was the first antibiotic, discovered by Alexander Fleming in 1928 [2]."
        let r = CitationGrounding.apply(t, evidence: ev)
        #expect(r.uncited == 1 && r.missing.flatMap { $0 }.contains("qualifier main"), "\(r.missing)")
        #expect(r.text.hasSuffix("in 1928 [2]."))
    }

    @Test func sentenceBoundaries() {
        #expect(CitationGrounding.lastSentence("First one. **Second** claim here. ") == "Second claim here")
        #expect(CitationGrounding.lastSentence("- 1. Item text") == "Item text")
        #expect(CitationGrounding.lastSentence("Line one\nLine two") == "Line two")
        #expect(CitationGrounding.lastSentence("* **6.12.115** is a longterm release") == "6.12.115 is a longterm release")
        #expect(CitationGrounding.lastSentence("* 2025: 1,431,419") == "2025: 1,431,419")
        #expect(CitationGrounding.lastSentence("Line one\n- American Red Cross: Its headquarters is in Washington, D.C. 20006") == "American Red Cross: Its headquarters is in Washington, D.C. 20006")
    }

    @Test func numbersMatchWholeTokens() {
        #expect(CitationGrounding.containsNumber("12", in: "about 12 people"))
        #expect(!CitationGrounding.containsNumber("12", in: "about 120 people"))
        #expect(!CitationGrounding.containsNumber("4", in: "version 4.2"))
        #expect(CitationGrounding.containsNumber("4.2", in: "version 4.2."))
    }

    @Test func addedDetailsTheSourceDoesNotStateLoseTheMarker() {  // attempt 3: content-word coverage
        let ev = [1: "X-rays are used for dental work: decay, roots and impacted teeth. Coatings and inks use the dispersion."]
        let ok = CitationGrounding.apply("Dental X-rays show decay, roots and impacted teeth [1].", evidence: ev)
        #expect(ok.uncited == 0, "\(ok.missing)")
        let bad = CitationGrounding.apply("Industrial uses cover paints, lubricants, sealants and adhesives [1].", evidence: ev)
        #expect(bad.uncited == 1 && bad.missing.first?.last?.hasPrefix("coverage") == true, "\(bad.missing)")
    }

    /// bars-2 (held-out-3 T3 misses): strengthenings need one of their forms near an anchor of the claim.
    @Test func strengtheningsNeedThePassage() {
        let imprint = [1: "Imprint. Example Media GmbH, Maarweg 165, 50825 Cologne, Germany. Register court Cologne HRB 1234."]
        let hq = CitationGrounding.apply("Its headquarters address is Maarweg 165, 50825 Cologne, Germany [1].", evidence: imprint)
        #expect(hq.uncited == 1 && hq.missing.flatMap { $0 }.contains("qualifier headquarters"), "\(hq.missing)")
        let bmw = [1: "BMW Headquarters. The global headquarters is located in Munich, Germany, at Petuelring 130."]
        #expect(CitationGrounding.apply("BMW is headquartered in Munich, Germany [1].", evidence: bmw).uncited == 0)
        let nobel = [1: "Onnes was awarded the Nobel Prize for Physics in 1913 for his low-temperature research."]
        let p = CitationGrounding.apply("For his pioneering work in low-temperature physics, Onnes was awarded the Nobel Prize in Physics in 1913 [1].", evidence: nobel)
        #expect(p.missing.flatMap { $0 }.contains("qualifier pioneering"), "\(p.missing)")
        let flash = [1: "LED flashlights with supercapacitors charge in much shorter periods of time, e.g., 90 seconds."]
        let f = CitationGrounding.apply("LED flashlights charge in as little as 90 seconds [1].", evidence: flash)
        #expect(f.missing.flatMap { $0 }.contains("qualifier as little as"), "\(f.missing)")
        let rule = [1: "Java 17 is required to run Gradle 9.0.0 builds."]
        #expect(CitationGrounding.apply("Gradle 9.0.0 must run on Java 17 [1].", evidence: rule).uncited == 0)
    }

    /// bars-2 (AT-248 c1): one cited source → a second source that alone passes the check joins the marker; never a
    /// source that lacks a detail, never an unfetched one, and nothing changes once two sources are cited.
    @Test func spreadAddsOnlyASecondSourceThatSupportsTheSentence() {
        let ev = [1: "Jenkins 2.528.1 LTS was released on 8 October 2025 with Java 21 support.",
                  2: "Jenkins LTS 2.528.1 was released on 8 October 2025; it adds Java 21 support.",
                  3: "Jenkins is an automation server written in Java.",
                  4: "Jenkins 2.528.1 LTS was released on 8 October 2025 with Java 21 support."]
        let r = CitationGrounding.spread("Jenkins 2.528.1 LTS was released on 8 October 2025 [1]. It is popular [1].", evidence: ev, candidates: [1, 2, 3])
        #expect(r.added == 1 && r.text == "Jenkins 2.528.1 LTS was released on 8 October 2025 [1, 2]. It is popular [1].", "\(r.text)")
        let none = CitationGrounding.spread("Jenkins 2.528.1 LTS added Java 25 support [1].", evidence: ev, candidates: [1, 2, 3])
        #expect(none.added == 0, "Java 25 is in no source")
        let two = CitationGrounding.spread("Jenkins 2.528.1 LTS was released on 8 October 2025 [1]. It runs Java [3].", evidence: ev, candidates: [1, 2, 3])
        #expect(two.added == 0)
        let unfetched = CitationGrounding.spread("Jenkins 2.528.1 LTS was released on 8 October 2025 [1].", evidence: ev, candidates: [1, 3])  // 4 = same text, not fetched
        #expect(unfetched.added == 0)
    }

    // MARK: bars-3 scope checks (A-M7-T03c lead decision 2)

    static let notes = """
        Release notes. The most current release of Neo4j is 2026.10.2. Neo4j 2026.10.2 6 November 2026 Bug fixes fixed a set of dependencies related to the bundled plugins. \
        Neo4j 5.26.33 6 November 2026 Bug fixes Server fixed an issue where a deleted entity would be returned when querying an index. \
        Neo4j 2026.10.1 23 October 2026 Bug fixes Admin fixed an issue that caused slow data ingestion during data load. Built with Go 1.27.3.
        """

    @Test func anItemOfAnotherVersionLosesTheMarker() {
        let ev = [1: Self.notes]
        let answer = "The latest release of Neo4j is 2026.10.2 [1].\n\nIt includes:\n* Fixed dependencies related to the bundled plugins [1].\n"
            + "* Server fix: a deleted entity was returned when querying an index [1].\n* Admin fix for slow data ingestion during data load [1]."
        let r = CitationGrounding.apply(answer, evidence: ev)
        #expect(r.text == "The latest release of Neo4j is 2026.10.2 [1].\n\nIt includes:\n* Fixed dependencies related to the bundled plugins [1].\n"
            + "* Server fix: a deleted entity was returned when querying an index.\n* Admin fix for slow data ingestion during data load.", "\(r.text)")
        #expect(r.missing.allSatisfy { $0 == ["version"] }, "\(r.missing)")
        // the sentence names the version it is listed under: kept
        let own = CitationGrounding.apply("Neo4j 5.26.33 fixed a deleted entity being returned when querying an index [1].", evidence: ev)
        #expect(own.uncited == 0, "\(own.missing)")
        // the heading that scopes a list is the nearest one on a heading line, not a sibling item
        let headed = CitationGrounding.apply("Neo4j 2026.10.2 is the latest [1].\n\nNeo4j 2026.10.1:\n* Admin fix for slow data ingestion during data load [1].",
                                             evidence: ev)
        #expect(headed.uncited == 0, "\(headed.missing)")
    }

    /// M7 at248: "macOS 27" (product + bare major) heads its section; the dotted "macOS 27.0.1" entry above it does not.
    @Test func aSeriesHeadingWithABareMajorHeadsItsSpan() {
        let ev = [4: "What's new in the updates for macOS 27. macOS 27.2 Suggestions in Messages help you act. macOS 27.0.1 "
            + "This update provides bug fixes for your Mac. macOS 27 Experience the new Siri AI Introducing Siri AI, an entirely "
            + "new version of Siri powered by Apple Intelligence that is more personal."]
        let text = "The latest macOS version is macOS 27.2.1.\n\n* macOS 27.2 adds Suggestions in Messages.\n"
            + "* The release introduced Siri AI, an entirely new version of Siri powered by Apple Intelligence [4].\n"
        #expect(CitationGrounding.apply(text, evidence: ev).uncited == 0)
        #expect(CitationGrounding.seriesHeadings(in: CitationGrounding.normalize(ev[4]!), products: ["macos"]).map(\.parts) == [[27], [27]])
    }

    @Test func otherProductsAndReferencePointsAreNotHeadings() {
        let ev = [1: "Latest release: Syncthing v2.1.7 What's changed. Built with Go 1.27.3. Fixes: handle missing max-sequence file entries; "
                  + "convert panics on bad data to protocol errors. Notable changes since 2.1.5: proxies with support for CONNECT can now be used."]
        let r = CitationGrounding.apply("The latest Syncthing is v2.1.7 [1].\n* Converts panics on bad data into protocol errors [1].\n"
            + "* Proxies with support for CONNECT can now be used [1].", evidence: ev)
        #expect(r.uncited == 0, "\(r.missing)")
    }

    @Test func theAnswersLatestVersionScopesALeadInNamingSeveral() {
        let ev = [1: "Most recent production release: FreeBSD 15.1 (June 16, 2026).",
                  2: "FreeBSD 15.0-RELEASE announcement. The installer now supports downloading and installing firmware packages after installation. "
                    + "Upgrading from FreeBSD 14.3 is supported. FreeBSD 15.1-RELEASE notes: the ps utility selects processes by real user IDs."]
        let answer = "The most recent production release is FreeBSD 15.1 [1].\n\nChanges in the 15.0-RELEASE and 15.1-RELEASE branches:\n"
            + "* The installer now supports downloading and installing firmware packages after installation [2].\n"
            + "* The ps utility now selects processes by real user IDs [2]."
        let r = CitationGrounding.apply(answer, evidence: ev)
        #expect(r.missing == [["version"]], "\(r.missing)")
        #expect(r.text.contains("after installation.\n") && r.text.hasSuffix("real user IDs [2]."))
        // an answer that scopes its list to both versions keeps both items
        let both = CitationGrounding.apply(answer.replacingOccurrences(of: "Changes in the", with: "Latest changes in the"), evidence: ev)
        #expect(both.uncited == 0, "\(both.missing)")
    }

    @Test func aRankOfTheMetropolitanAreaIsNotTheCitys() {
        let ev = [1: "The city of Bordeaux proper had a population of 267,991 in 2023, but together with its suburbs the Bordeaux "
                  + "metropolitan area had a population of 1,426,278 (2023), the sixth-most populous in France."]
        let city = CitationGrounding.apply("Bordeaux is the sixth-most populous city in France [1].", evidence: ev)
        #expect(city.missing == [["level city"]], "\(city.missing)")
        let metro = CitationGrounding.apply("The Bordeaux metropolitan area is the sixth-most populous in France [1].", evidence: ev)
        #expect(metro.uncited == 0, "\(metro.missing)")
        let figure = CitationGrounding.apply("The city of Bordeaux had a population of 267,991 in 2023 [1].", evidence: ev)
        #expect(figure.uncited == 0, "\(figure.missing)")
    }

    // MARK: bars-3 attach (AT-248 c1 lead decision 3)

    @Test func attachGivesAnUncitedSentenceOnlyASourceThatPassesAlone() {
        let ev = [1: "macOS 27.2 was released on October 26, 2026.",
                  2: "macOS 27 Golden Gate was released to the public on September 14, 2026, and requires Apple silicon.",
                  3: "Apple makes computers."]
        let text = "The latest macOS is macOS 27.2, released on October 26, 2026 [1].\n\nmacOS 27 was released on September 14, 2026.\n"
            + "It is the best release ever made by Apple in 2026.\n## Details\nRead more below:"
        let r = CitationGrounding.attach(text, evidence: ev, candidates: [1, 2, 3])
        #expect(r.text == "The latest macOS is macOS 27.2, released on October 26, 2026 [1].\n\nmacOS 27 was released on September 14, 2026 [2].\n"
            + "It is the best release ever made by Apple in 2026.\n## Details\nRead more below:", "\(r.text)")
        #expect(r.attached == [.init(claim: "macOS 27 was released on September 14, 2026", source: 2)])
        // the attached marker reads back as the same claim: keeping / standing / detach find exactly it
        #expect(CitationGrounding.detach(r.text, attached: r.attached) == text)
        #expect(CitationGrounding.standing(r.text, attached: r.attached) == r.attached)
        #expect(CitationGrounding.keeping(r.text, only: r.attached) == CitationGrounding.removingMarkers(text)
            .replacingOccurrences(of: "September 14, 2026.\nIt", with: "September 14, 2026 [2].\nIt"))
        // two sources cited already: nothing attached; unfetched sources never
        #expect(CitationGrounding.attach(r.text, evidence: ev, candidates: [1, 2, 3]).added == 0)
        #expect(CitationGrounding.attach(text, evidence: ev, candidates: [1, 3]).added == 0)
        // M7 at248: two sources in ONE combined pill is still one pill: an uncited sentence a source backs gets one
        let combined = "The latest macOS is macOS 27.2, released on October 26, 2026 [1, 2].\n\nmacOS 27 was released on September 14, 2026.\n"
        let c = CitationGrounding.attach(combined, evidence: ev, candidates: [1, 2, 3])
        #expect(c.attached == [.init(claim: "macOS 27 was released on September 14, 2026", source: 2)], "\(c.text)")
        // two pills of ONE source: the distinct-source rule still gives the uncited sentence a second source
        let two = "macOS 27.2 was released on October 26, 2026 [1]. It shipped on October 26, 2026 [1].\n\nmacOS 27 was released on September 14, 2026.\n"
        #expect(CitationGrounding.attach(two, evidence: ev, candidates: [1, 2, 3]).added == 1)
        // a list item's label is the topic, not a claim: its words do not count toward attach coverage
        let labelled = "macOS 27.2 shipped on October 26, 2026 [1, 2].\n* **Shipping timeline:** macOS 27 was released on September 14, 2026.\n"
        let l = CitationGrounding.attach(labelled, evidence: ev, candidates: [1, 2, 3])
        #expect(l.attached.map(\.source) == [2], "\(l.text)")
        #expect(CitationGrounding.withoutLabel("Release date: The major version was released") == "The major version was released")
        #expect(CitationGrounding.withoutLabel("Note: it shipped") == "Note: it shipped", "too short a rest: unchanged")
        #expect(CitationGrounding.withoutLabel("The ratio was 3:1 in the end") == "The ratio was 3:1 in the end")
        // a clause opened after a colon starts with a capital that is not a name
        #expect(CitationGrounding.clauseCased("macOS 27.2.1 (released 2026): Provides fixes. Apple: AI and macOS") == "macOS 27.2.1 (released 2026): provides fixes. Apple: AI and macOS")
        let ev5 = [1: "macOS 27.2 was released on October 26, 2026.",
                   5: "macOS 27 Golden Gate was released on September 14, 2026 with support requiring Apple silicon Macs."]
        let clause = "macOS 27.2 was released on October 26, 2026 [1].\n* **macOS 27 Golden Gate** (released September 14, 2026): "
            + "Brings support requiring Apple silicon Macs.\n"
        #expect(CitationGrounding.attach(clause, evidence: ev5, candidates: [1, 5]).attached.map(\.source) == [5])
        // a title-case label is a heading, not a name: the model's own marker stands (its body's names still count)
        let ev6 = [5: "macOS 27 is the first version to run exclusively on Macs with Apple silicon."]
        #expect(CitationGrounding.apply("Hardware Requirement: It is the first version to run exclusively on Macs with Apple silicon [5].", evidence: ev6).uncited == 0)
        #expect(CitationGrounding.apply("Hardware Requirement: It is the first version to run exclusively on Macs with Intel chips [5].", evidence: ev6).uncited == 1)
        // code is never touched
        let code = "Run `macOS 27 was released on September 14, 2026` [1]."
        #expect(CitationGrounding.attach(code, evidence: ev, candidates: [1, 2]).added == 0)
    }
}
