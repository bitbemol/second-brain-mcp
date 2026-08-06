import Darwin
import Foundation

/// Loads optional vault instructions through a small, regular-file-only boundary.
enum CustomInstructionsLoader {
    /// Maximum custom instruction bytes accepted at server startup.
    static let maximumBytes = 64 * 1024

    /// Reads `INSTRUCTIONS.md` without following a symlink or special file.
    ///
    /// The opened descriptor is checked with `fstat`, and reading stops one byte
    /// beyond the limit. This keeps stale path metadata, a growing file, a FIFO,
    /// or an outside-pointing symlink from blocking or exhausting startup.
    ///
    /// - Parameter vaultPath: Configured vault root.
    /// - Returns: Trimmed UTF-8 instructions, or `nil` when absent or unsafe.
    static func load(vaultPath: String) -> String? {
        let canonicalVault = URL(fileURLWithPath: vaultPath)
            .standardized
            .resolvingSymlinksInPath()
        let url = canonicalVault.appendingPathComponent("INSTRUCTIONS.md")

        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else {
            return nil
        }

        var data = Data()
        do {
            while data.count <= maximumBytes,
                  let chunk = try handle.read(
                    upToCount: min(16 * 1024, maximumBytes + 1 - data.count)
                  ),
                  !chunk.isEmpty {
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard data.count <= maximumBytes,
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
