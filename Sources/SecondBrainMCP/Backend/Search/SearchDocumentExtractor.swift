import Foundation

/// Result of format validation and projection into searchable sections.
struct ExtractedSearchDocument: Sendable {
    let document: SearchDocument
    let truncatedFields: Set<SearchField>

    /// Whether any searchable field was narrowed by an extraction ceiling.
    var truncated: Bool { !truncatedFields.isEmpty }
}

/// Validates stored text, applies confidentiality policy, and extracts search fields.
enum SearchDocumentExtractor {
    struct ResourceLimit: Error, Sendable {}

    private struct MarkdownMetadata {
        let title: String?
        let tags: [String]
        let lastLineIndex: Int?
        let truncatedFields: Set<SearchField>
    }

    private struct BoundedText {
        let value: String
        let truncated: Bool
    }

    private struct MarkdownFence: Equatable {
        let marker: Character
        let length: Int
        let remainderIsWhitespace: Bool
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
        maximumMetadataBytes: Int = SearchResourceLimits.default.maximumMetadataBytes,
        maximumStructuredValues: Int = SearchResourceLimits.default
            .maximumStructuredValuesPerFile,
        maximumPDFPages: Int = SearchResourceLimits.default.maximumPDFPagesPerFile,
        maximumPDFTextBytes: Int = SearchResourceLimits.default.maximumPDFTextBytesPerFile
    ) throws -> ExtractedSearchDocument {
        if format == .pdf {
            return try PDFSearchDocumentExtractor.extract(
                data: originalData,
                path: path,
                maximumPages: maximumPDFPages,
                maximumTextBytes: maximumPDFTextBytes,
                maximumMetadataCharacters: maximumMetadataCharacters,
                maximumMetadataBytes: maximumMetadataBytes
            )
        }
        if format == .canvas {
            do {
                try JSONSyntaxValidator.validate(
                    originalData,
                    rejectingDuplicateObjectKeys: true,
                    maximumValueCount: maximumStructuredValues
                )
            } catch JSONSyntaxValidator.ValidationError.excessiveValueCount {
                throw ResourceLimit()
            } catch JSONSyntaxValidator.ValidationError.excessiveNesting {
                throw ResourceLimit()
            }
        }
        try Task.checkCancellation()
        let data: Data
        if format == .har {
            do {
                data = try HARSensitiveDataSanitizer.sanitize(
                    originalData,
                    maximumValueCount: maximumStructuredValues
                ).data
            } catch is HARSensitiveDataSanitizer.ResourceLimit {
                throw ResourceLimit()
            }
        } else {
            data = originalData
        }

        try Task.checkCancellation()
        try SensitiveContentPolicy.validate(data, format: format, path: path)
        try Task.checkCancellation()
        if format == .canvas {
            let inspection = try CanvasDocumentValidator.inspect(jsonData: data)
            try Task.checkCancellation()
            return try canvasDocument(
                inspection: inspection,
                path: path,
                maximumSections: maximumSections,
                maximumMetadataCharacters: maximumMetadataCharacters,
                maximumMetadataBytes: maximumMetadataBytes
            )
        }
        try validateFormat(data: data, path: path, format: format)
        try Task.checkCancellation()
        let text = try TextFileSupport.stringPreservingByteOrderMark(from: data)

        if format == .markdown {
            let markdownText = text.first == "\u{FEFF}"
                ? String(text.dropFirst()) : text
            return try markdownDocument(
                text: markdownText,
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
            truncatedFields: title.truncated ? [.title] : []
        )
    }

    private static func canvasDocument(
        inspection: CanvasInspection,
        path: String,
        maximumSections: Int,
        maximumMetadataCharacters: Int,
        maximumMetadataBytes: Int
    ) throws -> ExtractedSearchDocument {
        var sections: [SearchSection] = []
        sections.reserveCapacity(min(inspection.nodes.count, maximumSections))
        var truncatedFields: Set<SearchField> = inspection.nodes.count > maximumSections
            ? [.content] : []

        for node in inspection.nodes.prefix(max(maximumSections, 0)) {
            try Task.checkCancellation()
            let field: String
            switch node.kind {
            case .text: field = "text"
            case .file: field = "file"
            case .link: field = "url"
            case .group: field = "label"
            }
            guard !node.searchText.isEmpty else { continue }
            let location: VaultSearchLocation?
            if node.id.utf8.count <= SearchRequestLimits.maximumLocatorBytes {
                location = VaultSearchLocation(
                    nodeID: node.id,
                    nodeType: node.kind.rawValue,
                    field: field
                )
            } else {
                // Never return a truncated identifier that cannot locate its
                // node, and never let one locator make a result unencodable.
                location = nil
                truncatedFields.insert(.content)
            }
            sections.append(SearchSection(
                heading: nil,
                location: location,
                content: node.searchText,
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
            truncatedFields: title.truncated
                ? truncatedFields.union([.title]) : truncatedFields
        )
    }

    private static func validateFormat(
        data: Data,
        path: String,
        format: FileFormat
    ) throws {
        switch format {
        case .canvas:
            preconditionFailure("Canvas projection is validated before this switch")
        case .har:
            _ = try HARInspector.inspect(data: data)
        case .patch:
            _ = try PatchFileOperations.inspect(data: data, path: path)
        case .json:
            do {
                try JSONSyntaxValidator.validate(data)
            } catch JSONSyntaxValidator.ValidationError.excessiveNesting {
                throw ResourceLimit()
            }
        case .csv:
            _ = try CSVDocumentInspector.inspect(
                TextFileSupport.stringPreservingByteOrderMark(from: data)
            )
        case .markdown, .log:
            break
        case .png, .jpeg, .gif, .webp, .heic, .tiff, .bmp:
            throw VaultSearchRequestError.unsupportedFormat(format)
        case .pdf:
            preconditionFailure("PDF projection is handled before text validation")
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
        var fence: MarkdownFence?
        var firstLevelOneHeading: String?
        var truncatedFields = metadata.truncatedFields
        if lineProjection.truncated {
            truncatedFields.formUnion([.heading, .content])
            if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
               metadata.lastLineIndex == nil {
                // The global line ceiling, rather than the front-matter
                // ceiling, may have hidden later title/tags and the closing
                // delimiter.
                truncatedFields.formUnion([.title, .tags])
            }
        }

        func markUnseenBodyFields() {
            truncatedFields.formUnion([.heading, .content])
            if metadata.title?.isEmpty != false,
               firstLevelOneHeading == nil {
                truncatedFields.insert(.title)
            }
        }

        func flush(endingAt lineEnd: Int) {
            guard currentHeading != nil || !currentContent.isEmpty else { return }
            guard sections.count < maximumSections else {
                markUnseenBodyFields()
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
                    } else if fence?.marker == marker.marker,
                              marker.length >= fence!.length,
                              marker.remainderIsWhitespace {
                        fence = nil
                    }
                    currentContent.append(line)
                    continue
                }
                if fence == nil, let parsedHeading = heading(in: line) {
                    flush(endingAt: index)
                    guard sections.count < maximumSections else {
                        markUnseenBodyFields()
                        break
                    }
                    let bounded = boundedMetadata(
                        parsedHeading.text,
                        maximumCharacters: maximumMetadataCharacters,
                        maximumBytes: maximumMetadataBytes
                    )
                    if bounded.truncated {
                        truncatedFields.insert(.heading)
                        if parsedHeading.level == 1,
                           metadata.title?.isEmpty != false,
                           firstLevelOneHeading == nil {
                            truncatedFields.insert(.title)
                        }
                    }
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
        if lineProjection.truncated,
           metadata.title?.isEmpty != false,
           firstLevelOneHeading == nil {
            truncatedFields.insert(.title)
        }

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
        if title.truncated { truncatedFields.insert(.title) }

        return ExtractedSearchDocument(
            document: SearchDocument(
                path: path,
                format: .markdown,
                title: title.value,
                tags: metadata.tags,
                sections: sections
            ),
            truncatedFields: truncatedFields
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
                truncatedFields: []
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
                truncatedFields: lines.count > maximumLines + 1
                    ? [.title, .heading, .tags, .content] : []
            )
        }

        var title: String?
        var tags: [String] = []
        var aggregateTagBytes = 0
        var readingBlockTags = false
        var truncatedFields = Set<SearchField>()

        func appendTag(_ raw: String) {
            guard tags.count < maximumTags else {
                truncatedFields.insert(.tags)
                return
            }
            let rawBound = utf8Prefix(raw, maximumBytes: maximumMetadataBytes)
            if rawBound.truncated { truncatedFields.insert(.tags) }
            let cleaned = cleanYAMLScalar(rawBound.value)
            let remaining = max(maximumAggregateTagBytes - aggregateTagBytes, 0)
            let bounded = boundedMetadata(
                cleaned,
                maximumCharacters: maximumMetadataCharacters,
                maximumBytes: min(maximumMetadataBytes, remaining)
            )
            if bounded.truncated { truncatedFields.insert(.tags) }
            guard !bounded.value.isEmpty, remaining > 0 else {
                if !cleaned.isEmpty { truncatedFields.insert(.tags) }
                return
            }
            tags.append(bounded.value)
            aggregateTagBytes += bounded.value.utf8.count
        }

        for index in lines.indices where index > 0 && index < closing {
            let rawLine = lines[index]
            let lineBound = utf8Prefix(rawLine, maximumBytes: maximumMetadataBytes)
            if lineBound.truncated {
                truncatedFields.formUnion([.title, .tags])
            }
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
                if bounded.truncated { truncatedFields.insert(.title) }
            } else if trimmed.lowercased().hasPrefix("tags:") {
                let raw = String(trimmed.dropFirst("tags:".count))
                    .trimmingCharacters(in: .whitespaces)
                if raw.isEmpty {
                    readingBlockTags = true
                } else {
                    let parsed = inlineTagScalars(raw)
                    if parsed.truncated { truncatedFields.insert(.tags) }
                    for scalar in parsed.values { appendTag(scalar) }
                }
            }
        }
        return MarkdownMetadata(
            title: title,
            tags: tags,
            lastLineIndex: closing,
            truncatedFields: truncatedFields
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

    private static func fenceMarker(in line: String) -> MarkdownFence? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " " {
            indentation += 1
            guard indentation <= 3 else { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex,
              line[index] == "`" || line[index] == "~" else { return nil }
        let marker = line[index]
        var length = 0
        while index < line.endIndex, line[index] == marker {
            length += 1
            index = line.index(after: index)
        }
        guard length >= 3 else { return nil }
        return MarkdownFence(
            marker: marker,
            length: length,
            remainderIsWhitespace: line[index...].allSatisfy(\.isWhitespace)
        )
    }

    private static func heading(
        in line: String
    ) -> (level: Int, text: String)? {
        var start = line.startIndex
        var indentation = 0
        while start < line.endIndex, line[start] == " " {
            indentation += 1
            guard indentation <= 3 else { return nil }
            start = line.index(after: start)
        }
        guard start < line.endIndex, line[start] != "\t" else { return nil }
        let trimmed = line[start...].trimmingCharacters(in: .whitespaces)
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
        if heading.last == "#" {
            var markerStart = heading.endIndex
            while markerStart > heading.startIndex {
                let previous = heading.index(before: markerStart)
                guard heading[previous] == "#" else { break }
                markerStart = previous
            }
            if markerStart == heading.startIndex
                || heading[heading.index(before: markerStart)].isWhitespace {
                heading = String(heading[..<markerStart])
                    .trimmingCharacters(in: .whitespaces)
            }
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
