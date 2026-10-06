import Foundation
import Testing

@testable import RadianCore

@Suite struct URLResolverTests {
    private func resolve(_ input: String) -> InputResolution? {
        URLResolver.resolve(input, engine: .duckDuckGo)
    }

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  example.com/path?q=1  ", "https://example.com/path?q=1"),
        ("sub.domain.example.co.uk", "https://sub.domain.example.co.uk"),
        ("example.com:8443/x", "https://example.com:8443/x"),
        ("https://example.com/a b".replacingOccurrences(of: " ", with: "%20"), "https://example.com/a%20b"),
        ("http://plain.example.com", "http://plain.example.com"),
        ("localhost", "http://localhost"),
        ("localhost:3000/admin", "http://localhost:3000/admin"),
        ("app.localhost:8080", "http://app.localhost:8080"),
        ("192.168.1.10", "http://192.168.1.10"),
        ("127.0.0.1:8000/docs", "http://127.0.0.1:8000/docs"),
        ("[::1]:8080", "http://[::1]:8080"),
        ("about:blank", "about:blank"),
        ("file:///tmp/page.html", "file:///tmp/page.html"),
        ("mailto:someone@example.com", "mailto:someone@example.com"),
        ("slack://open?team=T1", "slack://open?team=T1"),
    ])
    func treatsAddressesAsAddresses(input: String, expected: String) {
        #expect(resolve(input) == .url(URL(string: expected)!))
    }

    @Test(arguments: [
        "swift concurrency",
        "what is 1.5",
        "radian",
        "main.swift",
        "package.json",
        "999.999.999.999",
        "foo..bar",
        "a.b",
        "hello:world",
        "error:unexpected",
        "user@example.com",
    ])
    func treatsEverythingElseAsSearch(input: String) {
        #expect(resolve(input)?.isSearch == true)
    }

    @Test func blankInputResolvesToNothing() {
        #expect(resolve("") == nil)
        #expect(resolve("   \n") == nil)
    }

    @Test func searchQueriesAreEncodedSafely() throws {
        let resolution = try #require(resolve("c++ & rust?"))
        guard case .search(let url, let query) = resolution else {
            Issue.record("expected a search")
            return
        }
        #expect(query == "c++ & rust?")
        #expect(url.absoluteString == "https://duckduckgo.com/?q=c%2B%2B%20%26%20rust?")
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        #expect(decoded == "c++ & rust?")
    }

    @Test func everyEngineProducesAQueryURL() {
        for engine in SearchEngine.allCases {
            let url = engine.searchURL(for: "radian browser")
            #expect(url.scheme == "https")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "radian browser")
        }
    }
}

@Suite struct FuzzyMatchTests {
    @Test func rejectsCandidatesMissingCharacters() {
        #expect(FuzzyMatch.score(query: "xyz", candidate: "github") == nil)
        #expect(FuzzyMatch.score(query: "github.com", candidate: "git") == nil)
    }

    @Test func ranksPrefixAboveWordStartAboveMiddleAboveInitials() throws {
        let prefix = try #require(FuzzyMatch.score(query: "doc", candidate: "Docs Home"))
        let wordStart = try #require(FuzzyMatch.score(query: "doc", candidate: "Swift Docs"))
        let middle = try #require(FuzzyMatch.score(query: "doc", candidate: "Paradocs"))
        let initials = try #require(FuzzyMatch.score(query: "doc", candidate: "Deploy on Cloud"))
        #expect(prefix > wordStart)
        #expect(wordStart > middle)
        #expect(middle > initials)
    }

    @Test func prefersTighterMatchesAndIgnoresCase() throws {
        let exact = try #require(FuzzyMatch.score(query: "GIT", candidate: "git"))
        let longer = try #require(FuzzyMatch.score(query: "git", candidate: "GitHub"))
        #expect(exact > longer)
    }

    @Test func matchesTheStartsOfWords() {
        #expect(FuzzyMatch.score(query: "gh", candidate: "Git Hub") != nil)
        #expect(FuzzyMatch.score(query: "sd", candidate: "Swift Docs") != nil)
        // A run may continue past the start of a word: "swd" is "SW" + "D".
        #expect(FuzzyMatch.score(query: "swd", candidate: "Swift Docs") != nil)
        #expect(FuzzyMatch.score(query: "nsp", candidate: "New Space") != nil)
    }

    @Test(arguments: [
        ("doc", "Diode circuit"),
        ("wiki", "Search with Kagi"),
        ("wiki", "WKWebView reference"),
        ("wiki", "developer.apple.com/documentation/webkit/wkwebview"),
        ("fd", "Swift Docs"),
    ])
    func rejectsLettersThatAreMerelyInOrder(query: String, candidate: String) {
        #expect(FuzzyMatch.score(query: query, candidate: candidate) == nil)
    }

    @Test func multiWordQueriesNeedEveryWord() throws {
        let both = try #require(FuzzyMatch.score(query: "swift doc", candidate: "Swift.org - Documentation"))
        let phrase = try #require(FuzzyMatch.score(query: "swift doc", candidate: "Swift Docs"))
        #expect(phrase > both)
        #expect(FuzzyMatch.score(query: "doc swift", candidate: "Swift.org - Documentation") != nil)
        // "docs" is not in "Documentation", and every word must be found.
        #expect(FuzzyMatch.score(query: "swift docs", candidate: "Swift.org - Documentation") == nil)
        #expect(FuzzyMatch.score(query: "swift zebra", candidate: "Swift.org - Documentation") == nil)
        #expect(FuzzyMatch.score(query: "  swift  ", candidate: "Swift") != nil)
    }
}

@Suite struct BrowsingHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsRepeatVisitsAndKeepsTheLatestTitle() {
        var history = BrowsingHistory()
        let page = URL(string: "https://example.com/a")!
        history.record(url: page, title: "Old", at: now)
        history.record(url: page, title: "", at: now)
        history.record(url: page, title: "New", at: now)
        #expect(history.entries.count == 1)
        #expect(history.entries[page.absoluteString]?.visitCount == 3)
        #expect(history.entries[page.absoluteString]?.title == "New")
    }

    @Test func ignoresPagesThatAreNotOnTheWeb() {
        var history = BrowsingHistory()
        history.record(url: URL(string: "about:blank")!, title: "", at: now)
        history.record(url: URL(string: "file:///tmp/x.html")!, title: "Local", at: now)
        #expect(history.entries.isEmpty)
    }

    @Test func searchFavorsFrequentAndRecentPages() {
        var history = BrowsingHistory()
        let rare = URL(string: "https://swift.org/blog")!
        let frequent = URL(string: "https://swift.org/docs")!
        history.record(url: rare, title: "Swift Blog", at: now.addingTimeInterval(-30 * 86_400))
        for _ in 0..<20 { history.record(url: frequent, title: "Swift Docs", at: now) }
        #expect(history.search("swift", now: now).map(\.url) == [frequent, rare])
        #expect(history.search("nothing-matches", now: now).isEmpty)
        #expect(history.search("", now: now).isEmpty)
    }

    @Test func completesHostsFromTheirFirstLetters() {
        var history = BrowsingHistory()
        history.record(url: URL(string: "https://www.github.com/")!, title: "GitHub", at: now)
        history.record(url: URL(string: "https://gitlab.com/")!, title: "GitLab", at: now)
        history.record(url: URL(string: "https://www.github.com/")!, title: "GitHub", at: now)
        #expect(history.bestHostMatch(forPrefix: "gi")?.url.host == "www.github.com")
        #expect(history.bestHostMatch(forPrefix: "gitl")?.url.host == "gitlab.com")
        #expect(history.bestHostMatch(forPrefix: "g") == nil)
        #expect(history.bestHostMatch(forPrefix: "hub") == nil)
    }

    @Test func staysWithinItsLimit() {
        var history = BrowsingHistory(limit: 50)
        for index in 0..<200 {
            history.record(url: URL(string: "https://example.com/\(index)")!, title: "", at: now.addingTimeInterval(Double(index)))
        }
        #expect(history.entries.count <= 50)
        // The newest page is always kept.
        #expect(history.entries["https://example.com/199"] != nil)
    }
}
