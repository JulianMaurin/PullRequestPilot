import Foundation

/// One qualifier of a GitHub search query, such as `org:acme` or
/// `-label:"needs review"`.
struct SearchQualifier: Hashable, Sendable {
    let key: String
    let value: String
    let isExcluded: Bool

    init(key: String, value: String, isExcluded: Bool = false) {
        self.key = key
        self.value = value
        self.isExcluded = isExcluded
    }

    static func author(_ author: Author) -> SearchQualifier {
        SearchQualifier(key: "author", value: author.searchQualifierValue)
    }

    static func label(_ name: String) -> SearchQualifier {
        SearchQualifier(key: "label", value: name)
    }

    static func org(_ org: String) -> SearchQualifier {
        SearchQualifier(key: "org", value: org)
    }

    static func repo(_ nameWithOwner: String) -> SearchQualifier {
        SearchQualifier(key: "repo", value: nameWithOwner)
    }

    /// The same qualifier with a leading `-`, which excludes its matches.
    var excluded: SearchQualifier {
        SearchQualifier(key: key, value: value, isExcluded: true)
    }

    /// The qualifier as written in a query. Values with spaces or quotes are
    /// quoted, as GitHub requires.
    var text: String {
        let needsQuotes = value.contains(where: \.isWhitespace) || value.contains("\"")
        let written = needsQuotes ? "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" : value
        return "\(isExcluded ? "-" : "")\(key):\(written)"
    }

    /// Reads a single query term; nil for terms that aren't `key:value`.
    init?(term: String) {
        var rest = Substring(term)
        let isExcluded = rest.hasPrefix("-")
        if isExcluded { rest = rest.dropFirst() }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let key = rest[..<colon]
        var value = rest[rest.index(after: colon)...]
        guard !key.isEmpty, !value.isEmpty else { return nil }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = value.dropFirst().dropLast()
        }
        self.init(key: String(key), value: value.replacingOccurrences(of: "\\\"", with: "\""), isExcluded: isExcluded)
    }

    /// GitHub reads qualifier keys and these values without regard to case.
    func matches(_ other: SearchQualifier) -> Bool {
        isExcluded == other.isExcluded
            && key.caseInsensitiveCompare(other.key) == .orderedSame
            && value.caseInsensitiveCompare(other.value) == .orderedSame
    }
}

/// A GitHub search query read the way GitHub reads it: terms split on
/// whitespace, except inside double quotes.
struct SearchQuery: Equatable, Sendable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var terms: [String] {
        var terms: [String] = []
        var current = ""
        var isInQuotes = false
        var previous: Character?
        for character in text {
            if character == "\"", previous != "\\" {
                isInQuotes.toggle()
            }
            if character.isWhitespace, !isInQuotes {
                if !current.isEmpty { terms.append(current) }
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { terms.append(current) }
        return terms
    }

    func contains(_ qualifier: SearchQualifier) -> Bool {
        terms.contains { term in
            SearchQualifier(term: term)?.matches(qualifier) ?? false
        }
    }

    /// The query with `qualifier` added at the end, unless it already has it.
    func appending(_ qualifier: SearchQualifier) -> SearchQuery {
        guard !contains(qualifier) else { return self }
        return SearchQuery(text.isEmpty ? qualifier.text : "\(text) \(qualifier.text)")
    }
}
