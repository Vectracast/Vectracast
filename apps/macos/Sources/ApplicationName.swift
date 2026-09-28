import Foundation

/// Resolve another application's language independently of the launcher's own bundle localization.
enum ApplicationName {
    struct Metadata { let name: String; let searchTerms: [String] }
    static func resolve(_ bundle: Bundle, preferredLanguages: [String] = Locale.preferredLanguages) -> Metadata {
        let filename = bundle.bundleURL.deletingPathExtension().lastPathComponent
        func value(_ dictionary: [String: Any]?, _ key: String) -> String? {
            guard let text = dictionary?[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        var localized: [String: Any]?
        if let resources = bundle.resourceURL {
            for language in Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: preferredLanguages) {
                let url = resources.appendingPathComponent(language + ".lproj", isDirectory: true).appendingPathComponent("InfoPlist.strings")
                var dictionary = (try? Data(contentsOf: url)).flatMap { (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)) as? [String: Any] }
                if dictionary == nil {
                    // Recent system applications consolidate InfoPlist localizations into one table.
                    let tableURL = resources.appendingPathComponent("InfoPlist.loctable")
                    if let data = try? Data(contentsOf: tableURL), let table = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                        dictionary = table[language] as? [String: Any]
                    }
                }
                if value(dictionary, "CFBundleDisplayName") != nil || value(dictionary, "CFBundleName") != nil {
                    localized = dictionary; break
                }
            }
        }
        let raw = bundle.infoDictionary
        let name = value(localized, "CFBundleDisplayName") ?? value(localized, "CFBundleName") ?? value(raw, "CFBundleDisplayName") ?? value(raw, "CFBundleName") ?? filename
        let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
        let syllables = latin.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var phoneticTerms = [syllables.joined(), syllables.joined(separator: " ")]
        // Only Chinese names receive pinyin initials. English abbreviation sensitivity stays plugin-owned.
        if name.range(of: "\\p{Han}", options: .regularExpression) != nil {
            phoneticTerms.append(syllables.compactMap(\.first).map(String.init).joined())
        }
        var seen = Set<String>()
        let terms = ([filename] + phoneticTerms + [value(raw, "CFBundleDisplayName"), value(raw, "CFBundleName")].compactMap { $0 }).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return Metadata(name: name, searchTerms: terms)
    }
}
