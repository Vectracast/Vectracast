import Foundation

/// Explicit command entry only. Ambiguous names stay in root search for user selection.
enum CommandEntryMatcher {
    struct Candidate {
        let key: String
        let commandID: String
        let title: String
        let aliases: [String]
        var extensionName: String? = nil
    }
    struct Match { let key: String; let query: String }
    static func match(_ input: String, candidates: [Candidate]) -> Match? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [(key: String, query: String, length: Int, rank: Int)] = []
        for candidate in candidates {
            let names = candidate.aliases.map { ($0, 0) } + [(candidate.commandID, 1), (candidate.title, 2)] + (candidate.extensionName.map { [($0, 3)] } ?? [])
            for (raw, rank) in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let range = input.range(of: name, options: [.anchored, .caseInsensitive]) else { continue }
                let remainder = input[range.upperBound...]
                guard remainder.isEmpty || remainder.first?.isWhitespace == true else { continue }
                matches.append((candidate.key, remainder.trimmingCharacters(in: .whitespacesAndNewlines), name.count, rank))
            }
        }
        let ordered = matches.sorted { $0.length == $1.length ? $0.rank < $1.rank : $0.length > $1.length }
        guard let first = ordered.first,
              Set(ordered.filter { $0.length == first.length && $0.rank == first.rank }.map(\.key)).count == 1 else { return nil }
        return Match(key: first.key, query: first.query)
    }
}
