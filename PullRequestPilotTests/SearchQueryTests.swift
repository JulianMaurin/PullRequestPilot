import Testing
@testable import PullRequestPilot

@Suite("SearchQuery")
struct SearchQueryTests {

    @Test("terms split on whitespace but keep quoted values whole")
    func termsKeepQuotedValues() {
        let query = SearchQuery(#"is:pr  label:"needs review" -author:app/dependabot"#)
        #expect(query.terms == ["is:pr", #"label:"needs review""#, "-author:app/dependabot"])
    }

    @Test("a quoted label with spaces is found; a bare word of it is not")
    func containsQuotedLabel() {
        let query = SearchQuery(#"is:pr label:"needs review""#)
        #expect(query.contains(.label("needs review")))
        #expect(!query.contains(.label("needs")))
    }

    @Test("an excluded qualifier differs from the included one")
    func exclusionMatters() {
        let query = SearchQuery("is:pr -org:acme")
        #expect(query.contains(SearchQualifier.org("acme").excluded))
        #expect(!query.contains(.org("acme")))
    }

    @Test("keys and values compare without regard to case, quotes or not")
    func caseAndQuotesInsensitive() {
        let query = SearchQuery(#"Label:"Bug" ORG:Acme"#)
        #expect(query.contains(.label("bug")))
        #expect(query.contains(.org("acme")))
    }

    @Test("appending quotes values that need it and skips duplicates")
    func appending() {
        let query = SearchQuery("is:pr").appending(.label("needs review"))
        #expect(query.text == #"is:pr label:"needs review""#)
        #expect(query.appending(.label("needs review")) == query)
        #expect(SearchQuery("").appending(.org("acme")).text == "org:acme")
    }

    @Test("quotes inside a value are escaped and read back")
    func escapedQuotes() throws {
        let qualifier = SearchQualifier.label(#"say "hi""#)
        #expect(qualifier.text == #"label:"say \"hi\"""#)
        let parsed = try #require(SearchQualifier(term: qualifier.text))
        #expect(parsed.matches(qualifier))
    }

    @Test("a bot author is written with the app/ prefix")
    func botAuthor() {
        let bot = Author(login: "dependabot", avatarURL: nil, isBot: true)
        #expect(SearchQualifier.author(bot).excluded.text == "-author:app/dependabot")
    }

    @Test("terms that aren't key:value are not qualifiers")
    func plainWordsAreNotQualifiers() {
        #expect(SearchQualifier(term: "refactor") == nil)
        #expect(SearchQualifier(term: "label:") == nil)
        #expect(SearchQualifier(term: ":bug") == nil)
    }
}
