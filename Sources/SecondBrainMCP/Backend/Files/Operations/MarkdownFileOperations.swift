import Foundation

/// Adds Markdown front matter during creation when the caller did not provide it.
struct MarkdownFileOperations: Sendable {
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        var text = try TextFileSupport.string(from: input.data)
        if !MarkdownSupport.hasFrontmatter(text) {
            let title = MarkdownSupport.titleFromFilename(
                target.url.lastPathComponent
            )
            text = MarkdownSupport.generateFrontmatter(
                title: title,
                tags: input.tags
            ) + text
        }
        return PreparedFileWrite(
            data: Data(text.utf8),
            output: .text("Created \(target.relativePath)")
        )
    }
}

/// Interprets Markdown snapshots as bounded metadata; PDF metadata is catalog-owned.
struct FileMetadataReader: Sendable {

    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> FileOperationOutput {
        switch request.format {
        case .markdown:
            return .metadata(try markdown(
                target: target,
                snapshot: snapshot
            ))
        default:
            throw FileRoutingError.invalidReadOptions(
                "metadata view is unavailable for this format binding"
            )
        }
    }

    private func markdown(
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileReadMetadata {
        let text = try TextFileSupport.string(from: snapshot.data)
        let parsed = MarkdownSupport.metadata(from: text).value
        var incomplete = Set<FileMetadataField>()
        let title = FileMetadataTextBounds.display(
            parsed.title ?? firstHeading(in: parsed.body)
                ?? MarkdownSupport.titleFromFilename(target.url.lastPathComponent),
            field: .title,
            incomplete: &incomplete
        )
        var tags: [String] = []
        for tag in parsed.tags.sorted() {
            guard tag.utf8.count <= FileMetadataLimits.maximumStringBytes else {
                incomplete.insert(.tags)
                continue
            }
            guard tags.count < FileMetadataLimits.maximumTags else {
                incomplete.insert(.tags)
                break
            }
            tags.append(tag)
        }
        let links = try outgoingLinks(in: parsed.body)
        if links.incomplete { incomplete.insert(.outgoingLinkTargets) }
        return FileReadMetadata(
            format: .markdown,
            byteCount: snapshot.data.count,
            modifiedAt: snapshot.modifiedDate.map(Self.timestamp),
            title: title,
            tags: tags,
            wordCount: wordCount(in: parsed.body),
            outgoingLinkTargets: links.values,
            author: nil,
            pageCount: nil,
            pageLabels: nil,
            pageLabelsTruncated: nil,
            outline: nil,
            outlineTruncated: nil,
            incompleteFields: incomplete.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private func firstHeading(in body: String) -> String? {
        var start = body.startIndex
        while start < body.endIndex {
            let newline = body[start...].firstIndex(of: "\n") ?? body.endIndex
            let trimmed = body[start..<newline]
                .trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return String(heading) }
            }
            guard newline < body.endIndex else { break }
            start = body.index(after: newline)
        }
        return nil
    }

    private func wordCount(in body: String) -> Int {
        var count = 0
        var insideWord = false
        for character in body {
            if character.isWhitespace {
                insideWord = false
            } else if !insideWord {
                count += 1
                insideWord = true
            }
        }
        return count
    }

    private enum LinkSummaryStop: Error {
        case incomplete
    }

    private func outgoingLinks(in body: String) throws -> (values: [String], incomplete: Bool) {
        // Work is independent of the number of distinct targets that fit the response.
        let maximumOccurrences = 100_000
        var occurrences = 0
        var seen = Set<String>()
        var result: [String] = []
        var bytes = 0
        do {
            try ObsidianWikiLinkParser.forEach(in: body) { link in
                try Task.checkCancellation()
                occurrences += 1
                guard occurrences <= maximumOccurrences else { throw LinkSummaryStop.incomplete }
                let target = link.target
                guard !target.isEmpty, !seen.contains(target) else { return }
                let targetBytes = target.utf8.count
                guard targetBytes <= FileMetadataLimits.maximumStringBytes,
                      result.count < FileMetadataLimits.maximumOutgoingLinks,
                      targetBytes <= FileMetadataLimits.maximumOutgoingLinkBytes - bytes else {
                    throw LinkSummaryStop.incomplete
                }
                seen.insert(target)
                result.append(target)
                bytes += targetBytes
            }
        } catch LinkQuerySourceError.identifierTooLarge {
            return (result, true)
        } catch LinkSummaryStop.incomplete {
            return (result, true)
        }
        return (result, false)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}
