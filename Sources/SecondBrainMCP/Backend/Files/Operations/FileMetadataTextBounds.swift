import Foundation

/// Bounds display text without copying a complete, potentially large metadata attribute.
enum FileMetadataTextBounds {
    static func display(
        _ value: String?,
        field: FileMetadataField,
        incomplete: inout Set<FileMetadataField>
    ) -> String? {
        guard let value else { return nil }
        var prefix = Data(value.utf8.prefix(FileMetadataLimits.maximumStringBytes + 1))
        guard prefix.count > FileMetadataLimits.maximumStringBytes else { return value }
        incomplete.insert(field)
        prefix.removeLast()
        while !prefix.isEmpty {
            if let result = String(data: prefix, encoding: .utf8) { return result }
            prefix.removeLast()
        }
        return ""
    }
}
