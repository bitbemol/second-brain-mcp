import Foundation

/// Reads regular-file bytes without allowing stale metadata to bypass a size cap.
enum BoundedFileReader {
    private static let chunkBytes = 64 * 1024

    /// Reads at most one byte beyond a configured limit before rejecting the file.
    ///
    /// Reading in bounded chunks closes the gap between an earlier metadata check
    /// and the actual load. A file that grows after inspection cannot make this
    /// operation allocate its complete new size.
    ///
    /// - Parameters:
    ///   - url: Validated regular-file location to open.
    ///   - maximumBytes: Maximum number of bytes returned to the caller.
    ///   - path: Display path included in resource-policy diagnostics.
    /// - Returns: Complete file bytes when the opened file remains within the cap.
    /// - Throws: ``FileResourcePolicy/Violation`` or a file-handle error.
    static func read(
        from url: URL,
        maximumBytes: Int,
        path: String
    ) throws -> Data {
        guard maximumBytes >= 0 else {
            throw FileResourcePolicy.Violation(path: path, bytes: 0, limit: maximumBytes)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        while true {
            let remaining = maximumBytes - data.count
            let requestedBytes = min(chunkBytes, max(remaining, 1))
            guard let chunk = try handle.read(upToCount: requestedBytes),
                  !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw FileResourcePolicy.Violation(
                    path: path,
                    bytes: data.count,
                    limit: maximumBytes
                )
            }
        }
    }
}
