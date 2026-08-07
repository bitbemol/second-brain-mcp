import Foundation

/// Result of format validation and projection into searchable sections.
struct ExtractedSearchDocument: Sendable {
    let document: SearchDocument
    let truncated: Bool
}

/// Validates stored text, applies confidentiality policy, and extracts search fields.
enum SearchDocumentExtractor {
    private struct MarkdownMetadata {
        let title: String?
        let tags: [String]
        let lastLineIndex: Int?
        let truncated: Bool
    }

    private struct BoundedText {
        let value: String
        let truncated: Bool
    }

    private struct CanvasSearchDocument: Decodable {
        let nodes: [CanvasSearchNode]

        private enum CodingKeys: String, CodingKey { case nodes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodes = try container.decodeIfPresent(
                [CanvasSearchNode].self,
                forKey: .nodes
            ) ?? []
        }
    }

    private struct CanvasSearchNode: Decodable {
        let id: String
        let type: String
        let text: String?
        let file: String?
        let url: String?
        let label: String?
    }

    static func extract(
        data originalData: Data,
        path: String,
        format: FileFormat,
        maximumSections: Int,
        maximumMarkdownLines: Int = SearchResourceLimits.default.maximumMarkdownLines,
        maximumFrontMatterLines: Int = SearchResourceLimits.default.maximumFrontMatterLines,
        maximumTags: Int = SearchResourceLimits.default.maximumTags,
        maximumAggregateTagBytes: Int = SearchResourceLimits.default
            .maximumAggregateTagBytes,
        maximumMetadataCharacters: Int = SearchResourceLimits.default
            .maximumMetadataCharacters,
        maximumMetadataBytes: Int = SearchResourceLimits.default.maximumMetadataBytes
    ) throws -> ExtractedSearchDocument {
        let data: Data
        if format == .har {
            data = try HARSensitiveDataSanitizer.sanitize(originalData).data
        } else {
            data = originalData
        }

        try SensitiveContentPolicy.validate(data, format: format, path: path)
        try validateFormat(data: data, path: path, format: format)
        let text = try TextFileSupport.stringPreservingByteOrderMark(from: data)

        if format == .markdown {
            return try markdownDocument(
                text: text,
                path: path,
                maximumSections: maximumSections,
                maximumLines: maximumMarkdownLines,
                maximumFrontMatterLines: maximumFrontMatterLines,
                maximumTags: maximumTags,
                maximumAggregateTagBytes: maximumAggregateTagBytes,
                maximumMetadataCharacters: maximumMetadataCharacters,
                maximumMetadataBytes: maximumMetadataBytes
            )
        }
        if format == .canvas {
            return try canvasDocument(
                data: data,
                path: path,
                maximumSections: maximumSections,
                maximumMetadataCharacters: maximumMetadataCharacters,
                maximumMetadataBytes: maximumMetadataBytes
            )
        }

        let title = boundedMetadata(
            MarkdownSupport.titleFromFilename((path as NSString).lastPathComponent),
            maximumCharacters: maximumMetadataCharacters,
            maximumBytes: maximumMetadataBytes
        )
        let section = SearchSection(
            heading: nil,
            location: nil,
            content: text,
            lineStart: 1,
            lineEnd: TextLineScanner.lineCount(in: text)
        )
        return ExtractedSearchDocument(
            document: SearchDocument(
                path: path,
                format: format,
                title: title.value,
                tags: [],
                sections: [section]
            ),
            truncated: title.truncated
        )
    }

    private static func canvasDocument(
        data: Data,
        path: String,
        maximumSections: Int,
        maximumMetadataCharacters: Int,
        maximumMetadataBytes: Int
    ) throws -> ExtractedSearchDocument {
        let canvas = try JSONDecoder().decode(CanvasSearchDocument.self, from: data)
        var sections: [SearchSection] = []
        sections.reserveCapacity(min(canvas.nodes.count, maximumSections))
        var truncated = canvas.nodes.count > maximumSections

        for node in canvas.nodes.prefix(max(maximumSections, 0)) {
            try Task.checkCancellation()
            let projection: (field: String, value: String?)
            switch node.type {
            case "text": projection = ("text", node.text)
            case "file": projection = ("file", node.file)
            case "link": projection = ("url", node.url)
            case "group": projection = ("label", node.label)
            default: continue // The validator rejects unknown node kinds first.
            }
            guard let value = projection.value, !value.isEmpty else { continue }
            let nodeID = boundedMetadata(
                node.id,
                maximumCharacters: maximumMetadataCharacters,
                maximumBytes: maximumMetadataBytes
            )
            truncated = truncated || nodeID.truncated
            sections.append(SearchSection(
                heading: nil,
                location: VaultSearchLocation(
                    nodeID: nodeID.value,
                    nodeType: node.type,
                    field: projection.field
                ),
                content: value,
                lineStart: 1,
                lineEnd: 1
            ))
        }
        if sections.isEmpty {
            sections.append(SearchSection(
                heading: nil,
                location: nil,
                content: "",
                lineStart: 1,
                lineEnd: 1
            ))
        }

        let title = boundedMetadata(
            MarkdownSupport.titleFromFilename((path as NSString).lastPathComponent),
            maximumCharacters: maximumMetadataCharacters,
            maximumBytes: maximumMetadataBytes
        )
        return ExtractedSearchDocument(
            document: SearchDocument(
                path: path,
                format: .canvas,
                title: title.value,
                tags: [],
                sections: sections
            ),
            truncated: truncated || title.truncated
        )
    }

    private static func validateFormat(
        data: Data,
        path: String,
        format: FileFormat
    ) throws {
        switch format {
        case .canvas:
            try CanvasDocumentValidator.validate(jsonData: data)
        case .har:
            _ = try HARInspector.inspect(data: data)
        case .patch:
            _ = try PatchFileOperations.inspect(data: data, path: path)
        case .json:
            try JSONSyntaxValidator.validate(data)
        case .csv:
            _ = try CSVDocumentInspector.inspect(
                TextFileSupport.stringPreservingByteOrderMark(from: data)
            )
        case .markdown, .log:
            break
        case .png, .jpeg, .gif, .webp, .heic, .tiff, .bmp, .pdf:
            throw VaultSearchRequestError.unsupportedFormat(format)
        }
    }

    private static func markdownDocument(
        text: String,
        path: String,
        maximumSections: Int,
        maximumLines: Int,
        maximumFrontMatterLines: Int,
        maximumTags: Int,
        maximumAggregateTagBytes: Int,
        maximumMetadataCharacters: Int,
        maximumMetadataBytes: Int
    ) throws -> ExtractedSearchDocument {
        let lineProjection = try boundedLines(in: text, maximum: maximumLines)
        let lines = lineProjection.lines
        let metadata = frontMatter(
            in: lines,
            maximumLines: maximumFrontMatterLines,
            maximumTags: maximumTags,
            maximumAggregateTagBytes: maximumAggregateTagBytes,
            maximumMetadataCharacters: maximumMetadataCharacters,
            maximumMetadataBytes: maximumMetadataBytes
        )
        let bodyStart = metadata.lastLineIndex.map { $0 + 1 } ?? 0
        var sections: [SearchSection] = []
        var currentHeading: String?
        var currentStart = min(bodyStart + 1, max(lines.count, 1))
        var currentContent: [String] = []
        var fence: Character?
        var firstLevelOneHeading: String?
        var truncated = lineProjection.truncated || metadata.truncated

        func flush(endingAt lineEnd: Int) {
            guard currentHeading != nil || !currentContent.isEmpty else { return }
            guard sections.count < maximumSections else {
                truncated = true
                return
            }
            sections.append(SearchSection(
                heading: currentHeading,
                location: nil,
                content: currentContent.joined(separator: "\n"),
                lineStart: currentStart,
                lineEnd: max(currentStart, lineEnd)
            ))
        }

        if bodyStart < lines.count {
            for index in bodyStart..<lines.count {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                let line = lines[index]
                if let marker = fenceMarker(in: line) {
                    if fence == nil {
                        fence = marker
                    } else if fence == marker {
                        fence = nil
                    }
                    currentContent.append(line)
                    continue
                }
                if fence == nil, let parsedHeading = heading(in: line) {
                    flush(endingAt: index)
                    guard sections.count < maximumSections else {
                        truncated = true
                        break
                    }
                    let bounded = boundedMetadata(
                        parsedHeading.text,
                        maximumCharacters: maximumMetadataCharacters,
                        maximumBytes: maximumMetadataBytes
                    )
                    truncated = truncated || bounded.truncated
                    currentHeading = bounded.value
                    if parsedHeading.level == 1, firstLevelOneHeading == nil {
                        firstLevelOneHeading = bounded.value
                    }
                    currentStart = index + 1
                    currentContent = []
                } else {
                    currentContent.append(line)
                }
            }
        }
        flush(endingAt: max(lines.count, currentStart))

        if sections.isEmpty {
            sections = [SearchSection(
                heading: nil,
                location: nil,
                content: "",
                lineStart: max(bodyStart + 1, 1),
                lineEnd: max(lines.count, 1)
            )]
        }

        let fallbackTitle = MarkdownSupport.titleFromFilename(
            (path as NSString).lastPathComponent
        )
        let unboundedTitle = metadata.title?.isEmpty == false
            ? metadata.title!
            : firstLevelOneHeading ?? fallbackTitle
        let title = boundedMetadata(
            unboundedTitle,
            maximumCharacters: maximumMetadataCharacters,
            maximumBytes: maximumMetadataBytes
        )
        truncated = truncated || title.truncated

        return ExtractedSearchDocument(
            document: SearchDocument(
                path: path,
                format: .markdown,
                title: title.value,
                tags: metadata.tags,
                sections: sections
            ),
            truncated: truncated
        )
    }

    private static func boundedLines(
        in text: String,
        maximum: Int
    ) throws -> (lines: [String], truncated: Bool) {
        guard maximum > 0 else { return ([], !text.isEmpty) }
        let scalars = text.unicodeScalars
        var lines: [String] = []
        lines.reserveCapacity(min(maximum, 1_024))
        var start = scalars.startIndex
        var index = start
        var visited = 0

        while true {
            if visited.isMultiple(of: 4_096) { try Task.checkCancellation() }
            visited += 1
            if index == scalars.endIndex {
                guard lines.count < maximum else { return (lines, true) }
                lines.append(String(scalars[start..<index]))
                return (lines, false)
            }
            let scalar = scalars[index]
            guard CharacterSet.newlines.contains(scalar) else {
                index = scalars.index(after: index)
                continue
            }
            guard lines.count < maximum else { return (lines, true) }
            lines.append(String(scalars[start..<index]))
            var next = scalars.index(after: index)
            if scalar == "\r", next < scalars.endIndex, scalars[next] == "\n" {
                next = scalars.index(after: next)
            }
            start = next
            index = next
        }
    }

    private static func frontMatter(
        in lines: [String],
        maximumLines: Int,
        maximumTags: Int,
        maximumAggregateTagBytes: Int,
        maximumMetadataCharacters: Int,
        maximumMetadataBytes: Int
    ) -> MarkdownMetadata {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return MarkdownMetadata(
                title: nil,
                tags: [],
                lastLineIndex: nil,
                truncated: false
            )
        }
        let searchable = lines.indices.dropFirst().prefix(max(maximumLines, 0))
        guard let closing = searchable.first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return MarkdownMetadata(
                title: nil,
                tags: [],
                lastLineIndex: nil,
                truncated: lines.count > maximumLines + 1
            )
        }

        var title: String?
        var tags: [String] = []
        var aggregateTagBytes = 0
        var readingBlockTags = false
        var truncated = false

        func appendTag(_ raw: String) {
            guard tags.count < maximumTags else {
                truncated = true
                return
            }
            let rawBound = utf8Prefix(raw, maximumBytes: maximumMetadataBytes)
            truncated = truncated || rawBound.truncated
            let cleaned = cleanYAMLScalar(rawBound.value)
            let remaining = max(maximumAggregateTagBytes - aggregateTagBytes, 0)
            let bounded = boundedMetadata(
                cleaned,
                maximumCharacters: maximumMetadataCharacters,
                maximumBytes: min(maximumMetadataBytes, remaining)
            )
            truncated = truncated || bounded.truncated
            guard !bounded.value.isEmpty, remaining > 0 else {
                if !cleaned.isEmpty { truncated = true }
                return
            }
            tags.append(bounded.value)
            aggregateTagBytes += bounded.value.utf8.count
        }

        for index in lines.indices where index > 0 && index < closing {
            let rawLine = lines[index]
            let lineBound = utf8Prefix(rawLine, maximumBytes: maximumMetadataBytes)
            truncated = truncated || lineBound.truncated
            let trimmed = lineBound.value.trimmingCharacters(in: .whitespaces)

            if readingBlockTags {
                if trimmed.hasPrefix("-") {
                    appendTag(String(trimmed.dropFirst()))
                    continue
                }
                readingBlockTags = false
            }

            if trimmed.lowercased().hasPrefix("title:") {
                let raw = String(trimmed.dropFirst("title:".count))
                let decoded = cleanYAMLScalar(raw)
                let bounded = boundedMetadata(
                    decoded,
                    maximumCharacters: maximumMetadataCharacters,
                    maximumBytes: maximumMetadataBytes
                )
                title = bounded.value
                truncated = truncated || bounded.truncated
            } else if trimmed.lowercased().hasPrefix("tags:") {
                let raw = String(trimmed.dropFirst("tags:".count))
                    .trimmingCharacters(in: .whitespaces)
                if raw.isEmpty {
                    readingBlockTags = true
                } else {
                    let parsed = inlineTagScalars(raw)
                    truncated = truncated || parsed.truncated
                    for scalar in parsed.values { appendTag(scalar) }
                }
            }
        }
        return MarkdownMetadata(
            title: title,
            tags: tags,
            lastLineIndex: closing,
            truncated: truncated
        )
    }

    private static func inlineTagScalars(
        _ raw: String
    ) -> (values: [String], truncated: Bool) {
        var content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("[") {
            guard content.hasSuffix("]") else { return ([content], true) }
            content.removeFirst()
            content.removeLast()
        }

        var values: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in content {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                current.append(character)
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                continue
            }
            if character == ",", quote == nil {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        values.append(current)
        return (values, quote != nil || escaped)
    }

    private static func cleanYAMLScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""),
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func fenceMarker(in line: String) -> Character? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "`" }
        if trimmed.hasPrefix("~~~") { return "~" }
        return nil
    }

    private static func heading(
        in line: String
    ) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var count = 0
        for character in trimmed {
            guard character == "#" else { break }
            count += 1
        }
        guard (1...6).contains(count), trimmed.count > count else { return nil }
        let boundary = trimmed.index(trimmed.startIndex, offsetBy: count)
        guard trimmed[boundary].isWhitespace else { return nil }
        var heading = String(trimmed[boundary...])
            .trimmingCharacters(in: .whitespaces)
        while heading.last == "#" {
            heading.removeLast()
            heading = heading.trimmingCharacters(in: .whitespaces)
        }
        return heading.isEmpty ? nil : (count, heading)
    }

    private static func boundedMetadata(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> BoundedText {
        guard maximumCharacters > 0, maximumBytes > 0 else {
            return BoundedText(value: "", truncated: !value.isEmpty)
        }
        var result = ""
        result.reserveCapacity(min(value.utf8.count, maximumBytes))
        var scalarCount = 0
        var byteCount = 0
        var consumedAll = true
        for scalar in value.unicodeScalars {
            let scalarText = String(scalar)
            let scalarBytes = scalarText.utf8.count
            guard scalarCount < maximumCharacters,
                  byteCount + scalarBytes <= maximumBytes else {
                consumedAll = false
                break
            }
            result.unicodeScalars.append(scalar)
            scalarCount += 1
            byteCount += scalarBytes
        }
        return BoundedText(value: result, truncated: !consumedAll)
    }

    private static func utf8Prefix(
        _ value: String,
        maximumBytes: Int
    ) -> BoundedText {
        boundedMetadata(
            value,
            maximumCharacters: Int.max,
            maximumBytes: maximumBytes
        )
    }
}
