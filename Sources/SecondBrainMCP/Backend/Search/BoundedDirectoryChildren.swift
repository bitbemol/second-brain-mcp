import Foundation

enum BoundedDirectoryChildren {
    static func urls(
        below directory: URL,
        resourceKeys: Set<URLResourceKey>,
        maximumEntries: Int,
        scannedEntries: inout Int,
        limitError: @autoclosure () -> any Error
    ) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            if let enumerationError { throw enumerationError }
            return []
        }

        var children: [URL] = []
        while let child = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            scannedEntries += 1
            guard scannedEntries <= maximumEntries else {
                throw limitError()
            }
            children.append(child)
        }
        if let enumerationError { throw enumerationError }
        return children.sorted { $0.path < $1.path }
    }
}
