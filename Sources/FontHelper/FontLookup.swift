import Foundation
import CoreText

/// Finds installed font files with macOS's own font lookup, fresh at every call.
enum FontLookup {
    /// Every installed file of the family, the exact family-and-style match first.
    /// The font check then picks the file whose glyphs match Figma's export.
    static func candidates(family: String, style: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()

        func add(_ attrs: [String: Any], mandatory: [CFString]) {
            let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            let keys = NSSet(array: mandatory) as CFSet
            guard let found = CTFontDescriptorCreateMatchingFontDescriptors(desc, keys) as? [CTFontDescriptor] else { return }
            for d in found {
                guard let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL else { continue }
                if seen.contains(url.path) { continue }
                seen.insert(url.path)
                out.append(["path": url.path, "fontNumber": 0])
            }
        }

        add([kCTFontFamilyNameAttribute as String: family, kCTFontStyleNameAttribute as String: style],
            mandatory: [kCTFontFamilyNameAttribute, kCTFontStyleNameAttribute])
        add([kCTFontFamilyNameAttribute as String: family], mandatory: [kCTFontFamilyNameAttribute])
        return out
    }
}
