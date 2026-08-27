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

/// Interprets immutable snapshots as bounded content-free metadata.
struct FileMetadataReader: Sendable {
    private let pdfReader: PDFReader

    init(pdfReader: PDFReader) {
        self.pdfReader = pdfReader
    }

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
        case .pdf:
            return .metadata(try await pdfReader.metadata(
                target: target,
                snapshot: snapshot
            ))
        default:
            throw FileRoutingError.invalidReadOptions(
                "metadata view is supported only for markdown and pdf"
            )
        }
    }

    private func markdown(
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileReadMetadata {
        let text = try TextFileSupport.string(from: snapshot.data)
        let parsed = MarkdownSupport.metadata(from: text).value
        let title = bounded(
            parsed.title ?? firstHeading(in: parsed.body)
                ?? MarkdownSupport.titleFromFilename(target.url.lastPathComponent)
        )
        let tags = Array(parsed.tags.sorted().prefix(FileMetadataLimits.maximumTags))
            .map { bounded($0) }
        return FileReadMetadata(
            format: .markdown,
            byteCount: snapshot.data.count,
            modifiedAt: snapshot.modifiedDate.map(Self.timestamp),
            title: title,
            tags: tags,
            wordCount: wordCount(in: parsed.body),
            outgoingLinkTargets: outgoingLinks(in: parsed.body),
            author: nil,
            pageCount: nil,
            pageLabels: nil,
            pageLabelsTruncated: nil,
            outline: nil,
            outlineTruncated: nil
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

    private func outgoingLinks(in body: String) -> [String] {
        let patterns = [
            #"!?\[\[([^\]|]+)(?:\|[^\]]*)?\]\]"#,
            #"!?\[[^\]]*\]\(([^\s\)]+)(?:\s+[^\)]*)?\)"#,
        ]
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var candidates: [(offset: Int, target: String)] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            expression.enumerateMatches(
                in: body,
                range: range
            ) { match, _, stop in
                guard let match,
                      let capture = Range(match.range(at: 1), in: body) else {
                    return
                }
                candidates.append((
                    match.range.location,
                    String(body[capture])
                ))
                if candidates.count >= FileMetadataLimits.maximumOutgoingLinks * 2 {
                    stop.pointee = true
                }
            }
        }
        candidates.sort {
            $0.offset == $1.offset ? $0.target < $1.target : $0.offset < $1.offset
        }
        var seen = Set<String>()
        var result: [String] = []
        var bytes = 0
        for candidate in candidates {
            var target = candidate.target
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if target.hasPrefix("<"), target.hasSuffix(">"), target.count >= 2 {
                target = String(target.dropFirst().dropLast())
            }
            let lower = target.lowercased()
            guard !target.isEmpty,
                  !target.hasPrefix("#"),
                  !lower.hasPrefix("http://"),
                  !lower.hasPrefix("https://"),
                  !lower.hasPrefix("mailto:"),
                  !lower.hasPrefix("data:"),
                  seen.insert(target).inserted else {
                continue
            }
            let boundedTarget = bounded(target)
            let nextBytes = bytes + boundedTarget.utf8.count
            guard result.count < FileMetadataLimits.maximumOutgoingLinks,
                  nextBytes <= FileMetadataLimits.maximumOutgoingLinkBytes else {
                break
            }
            result.append(boundedTarget)
            bytes = nextBytes
        }
        return result
    }

    private func bounded(_ value: String) -> String {
        let data = Data(value.utf8)
        guard data.count > FileMetadataLimits.maximumStringBytes else {
            return value
        }
        var end = FileMetadataLimits.maximumStringBytes
        while end > 0 {
            if let result = String(data: data.prefix(end), encoding: .utf8) {
                return result
            }
            end -= 1
        }
        return ""
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}
