import Foundation
import MCP

/// Maps transport-neutral search results into escaped MCP values.
enum SearchToolResultMapper {
    enum MappingError: Error { case responseTooLarge }

    static func success(_ response: VaultSearchResponse) throws -> CallTool.Result {
        var bounded = response
        while try encodedResultsByteCount(bounded.results)
                > SearchRequestLimits.maximumWireResultPayloadBytes {
            // Production already uses this exact result budget. A custom
            // service must not advance a cursor over a result removed here.
            guard bounded.nextCursor == nil else {
                throw MappingError.responseTooLarge
            }
            guard !bounded.results.isEmpty else { break }
            bounded = replacing(
                bounded,
                results: Array(bounded.results.dropLast()),
                samples: bounded.resourceLimitSamples,
                moreResultsAvailable: true
            )
        }
        while true {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [
                .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
            ]
            let json = String(
                decoding: try encoder.encode(bounded),
                as: UTF8.self
            )
            let result = try CallTool.Result(
                content: [.text(text: json, annotations: nil, _meta: nil)],
                structuredContent: structuredContent(bounded)
            )
            if try JSONEncoder().encode(result).count
                <= SearchRequestLimits.maximumWireResponseBytes {
                return result
            }
            guard !bounded.resourceLimitSamples.isEmpty else {
                throw MappingError.responseTooLarge
            }
            bounded = replacing(
                bounded,
                results: bounded.results,
                samples: Array(bounded.resourceLimitSamples.dropLast()),
                moreResultsAvailable: bounded.moreResultsAvailable
            )
        }
    }

    private static func replacing(
        _ response: VaultSearchResponse,
        results: [VaultSearchResult],
        samples: [VaultSearchResourceLimit],
        moreResultsAvailable: Bool
    ) -> VaultSearchResponse {
        VaultSearchResponse(
            strategy: response.strategy,
            results: results,
            searchedFileCount: response.searchedFileCount,
            skippedFileCount: response.skippedFileCount,
            skippedSensitiveFileCount: response.skippedSensitiveFileCount,
            resourceLimitedFileCount: response.resourceLimitedFileCount,
            moreResultsAvailable: moreResultsAvailable,
            coverageIncomplete: response.coverageIncomplete,
            minimumRelevance: response.minimumRelevance,
            resourceLimitSamples: samples,
            nextCursor: response.nextCursor,
            omittedResultCountLowerBound: response.omittedResultCountLowerBound
                + max(response.results.count - results.count, 0),
            pdfSummary: response.pdfSummary
        )
    }

    private static func encodedResultsByteCount(
        _ results: [VaultSearchResult]
    ) throws -> Int {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(results).count
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static func structuredContent(_ response: VaultSearchResponse) -> Value {
        var values: [String: Value] = [
            "strategy": .string(response.strategy.rawValue),
            "results": .array(response.results.map(resultValue)),
            "searched_file_count": .int(response.searchedFileCount),
            "skipped_file_count": .int(response.skippedFileCount),
            "skipped_sensitive_file_count": .int(response.skippedSensitiveFileCount),
            "resource_limited_file_count": .int(response.resourceLimitedFileCount),
            "resource_limit_samples": .array(response.resourceLimitSamples.map {
                .object([
                    "path": .string($0.path),
                    "reason": .string($0.reason.rawValue),
                    "impact": .string($0.impact.rawValue),
                ])
            }),
            "minimum_relevance": .double(response.minimumRelevance),
            "more_results_available": .bool(response.moreResultsAvailable),
            "omitted_result_count_lower_bound": .int(
                response.omittedResultCountLowerBound
            ),
            "pdf_summary": pdfSummaryValue(response.pdfSummary),
            "coverage_incomplete": .bool(response.coverageIncomplete),
            "truncated": .bool(response.truncated),
        ]
        if let cursor = response.nextCursor {
            values["next_cursor"] = .string(cursor)
        }
        return .object(values)
    }

    private static func pdfSummaryValue(_ summary: VaultSearchPDFSummary) -> Value {
        .object([
            "examined_file_count": .int(summary.examinedFileCount),
            "metadata_only_file_count": .int(summary.metadataOnlyFileCount),
            "extracted_file_count": .int(summary.extractedFileCount),
            "partial_file_count": .int(summary.partialFileCount),
            "no_extractable_text_file_count": .int(
                summary.noExtractableTextFileCount
            ),
            "unavailable_file_count": .int(summary.unavailableFileCount),
            "ocr_performed": .bool(summary.ocrPerformed),
        ])
    }

    private static func resultValue(_ result: VaultSearchResult) -> Value {
        var values: [String: Value] = [
            "path": .string(result.path),
            "format": .string(result.format.rawValue),
            "area": .string(result.area.rawValue),
            "title": .string(result.title),
            "snippet": .string(result.snippet),
            "line_start": .int(result.lineStart),
            "line_end": .int(result.lineEnd),
            "matched_fields": .array(result.matchedFields.map { .string($0.rawValue) }),
            "relevance": .double(result.relevance),
            "term_coverage": .double(result.termCoverage),
            "complete_query_fields": .array(
                result.completeQueryFields.map { .string($0.rawValue) }
            ),
        ]
        if let heading = result.heading { values["heading"] = .string(heading) }
        if let location = result.location {
            values["location"] = .object([
                "node_id": .string(location.nodeID),
                "node_type": .string(location.nodeType),
                "field": .string(location.field),
            ])
        }
        if let page = result.physicalPage { values["physical_page"] = .int(page) }
        if let page = result.printedPage { values["printed_page"] = .string(page) }
        if let kind = result.pdfPageKind {
            values["pdf_page_kind"] = .string(kind.rawValue)
        }
        if let status = result.pdfTextExtractionStatus {
            values["pdf_text_extraction_status"] = .string(status.rawValue)
        }
        return .object(values)
    }
}
