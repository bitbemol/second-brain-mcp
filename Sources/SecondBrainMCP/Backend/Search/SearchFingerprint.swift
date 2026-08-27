import CryptoKit
import Foundation

/// Incremental, length-delimited fields avoid ambiguous concatenation and corpus-sized JSON.
struct SearchFingerprint {
    private var digest = SHA256()

    init(domain: String) { append(domain) }

    mutating func append(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func append(_ value: Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { digest.update(bufferPointer: $0) }
        digest.update(data: value)
    }

    mutating func append(_ value: String?) {
        append(value == nil ? "absent" : "present")
        if let value { append(value) }
    }

    mutating func append(_ locator: VaultSearchResult) {
        append(locator.path)
        append(locator.format.rawValue)
        append(locator.page.map(String.init))
        append(locator.canvasNodeID)
        append(locator.canvasField)
    }

    mutating func append(_ atom: SearchAtom) {
        append(atom.locator)
        append(atom.text)
        append(atom.metadata == nil ? "no-metadata" : "metadata")
        let tags = atom.metadata?.tags.sorted() ?? []
        append(String(tags.count))
        for tag in tags { append(tag) }
        append(atom.metadata?.created)
    }

    var value: String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func locatorID(_ locator: VaultSearchResult) -> String {
        var fingerprint = Self(domain: "search-locator-v1")
        fingerprint.append(locator)
        return fingerprint.value
    }

    static func precedes(_ lhs: SearchAtom, _ rhs: SearchAtom) -> Bool {
        let a = lhs.locator
        let b = rhs.locator
        if a.path != b.path { return a.path < b.path }
        if a.format != b.format { return a.format.rawValue < b.format.rawValue }
        if a.page != b.page { return (a.page ?? 0) < (b.page ?? 0) }
        if a.canvasNodeID != b.canvasNodeID {
            return (a.canvasNodeID ?? "") < (b.canvasNodeID ?? "")
        }
        if a.canvasField != b.canvasField {
            return (a.canvasField ?? "") < (b.canvasField ?? "")
        }
        if lhs.text != rhs.text { return lhs.text < rhs.text }
        let aTags = lhs.metadata?.tags.sorted() ?? []
        let bTags = rhs.metadata?.tags.sorted() ?? []
        if aTags != bTags { return aTags.lexicographicallyPrecedes(bTags) }
        return (lhs.metadata?.created ?? "") < (rhs.metadata?.created ?? "")
    }
}
