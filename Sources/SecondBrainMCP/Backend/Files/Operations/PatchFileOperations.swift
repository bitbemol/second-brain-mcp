import Foundation

/// Validates and summarizes unified diff files without applying them.
struct PatchFileOperations: Sendable {
    /// Errors produced by unified-diff structure validation.
    enum PatchError: Error, CustomStringConvertible {
        /// The text contains neither a Git diff header nor old/new file headers.
        case invalidStructure

        /// Human-readable unified-diff validation failure.
        var description: String { "Input is not a recognizable unified diff" }
    }

    /// Validates a centrally loaded patch before generic persistence.
    ///
    /// - Parameters:
    ///   - input: Centrally validated unified-diff bytes.
    ///   - target: Validated destination included in the patch summary.
    /// - Returns: Valid patch bytes and their compact creation summary.
    /// - Throws: ``PatchError`` when unified-diff structure is absent.
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        let summary = try Self.inspect(data: input.data, path: target.relativePath)
        return PreparedFileWrite(data: input.data, output: .text("Created \(target.relativePath)\n\(summary)"))
    }

    /// Returns a patch summary followed by the complete snapshot diff.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        let summary = try Self.inspect(data: snapshot.data, path: target.relativePath)
        return .text(summary + "\n\n" + (try TextFileSupport.string(from: snapshot.data)))
    }

    /// Validates a unified diff and counts changed files, hunks, and lines.
    ///
    /// - Parameters:
    ///   - data: UTF-8 patch data.
    ///   - path: Vault-relative path displayed in the summary.
    /// - Returns: A compact, line-oriented patch summary.
    static func inspect(data: Data, path: String) throws -> String {
        let text = try TextFileSupport.string(from: data)
        var affectedFileSections = 0
        var hunks = 0
        var additions = 0
        var deletions = 0
        var hasValidGitHeader = false
        var currentGitSectionIsValid = false
        var awaitingNewFileHeader = false
        var pendingOldFileIsValid = false
        var hasFileHeader = false
        var currentFileHeaderIsValid = false
        var insideHunk = false
        var hasSupportedMetadata = false

        TextLineScanner.forEachLine(in: text) { scalarLine, _ in
            let line = String(scalarLine)
            if line.hasPrefix("diff --git ") {
                let paths = line.dropFirst("diff --git ".count)
                    .split(whereSeparator: \.isWhitespace)
                currentGitSectionIsValid = paths.count >= 2
                if currentGitSectionIsValid {
                    hasValidGitHeader = true
                    // Count the structural section, not whitespace-split paths.
                    // Git quotes filenames containing spaces, so attempting to
                    // derive identity from split tokens can double-count one file.
                    affectedFileSections += 1
                }
                awaitingNewFileHeader = false
                pendingOldFileIsValid = false
                currentFileHeaderIsValid = false
                insideHunk = false
            } else if line.hasPrefix("--- ") {
                let rawFile = String(line.dropFirst(4))
                    .split(separator: "\t", omittingEmptySubsequences: false)
                    .first.map(String.init) ?? ""
                pendingOldFileIsValid = !rawFile.isEmpty && rawFile != "/dev/null"
                awaitingNewFileHeader = true
                currentFileHeaderIsValid = false
                insideHunk = false
            } else if line.hasPrefix("+++ "), awaitingNewFileHeader {
                let rawFile = String(line.dropFirst(4))
                    .split(separator: "\t", omittingEmptySubsequences: false)
                    .first.map(String.init) ?? ""
                let newFileIsValid = !rawFile.isEmpty && rawFile != "/dev/null"
                currentFileHeaderIsValid = !rawFile.isEmpty
                    && (newFileIsValid || pendingOldFileIsValid)
                if currentFileHeaderIsValid, !currentGitSectionIsValid {
                    affectedFileSections += 1
                }
                hasFileHeader = hasFileHeader || currentFileHeaderIsValid
                awaitingNewFileHeader = false
            } else if line.hasPrefix("@@"),
                      line.dropFirst(2).contains("@@"),
                      currentFileHeaderIsValid {
                hunks += 1
                insideHunk = true
            } else if line.hasPrefix("+") && insideHunk {
                additions += 1
            } else if line.hasPrefix("-") && insideHunk {
                deletions += 1
            } else if currentGitSectionIsValid,
                      Self.isSupportedMetadataLine(line) {
                hasSupportedMetadata = true
            }
        }

        guard (hasFileHeader && hunks > 0)
                || (hasValidGitHeader && hasSupportedMetadata) else {
            throw PatchError.invalidStructure
        }
        return "Patch: \(path)\nFiles: \(affectedFileSections) · Hunks: \(hunks) · +\(additions) / -\(deletions)"
    }

    /// Recognizes valid Git diff bodies that do not need textual hunks.
    private static func isSupportedMetadataLine(_ line: String) -> Bool {
        [
            "old mode ", "new mode ", "new file mode ", "deleted file mode ",
            "similarity index ", "dissimilarity index ", "rename from ",
            "rename to ", "copy from ", "copy to ", "Binary files ",
            "GIT binary patch",
        ].contains { line.hasPrefix($0) }
    }
}
