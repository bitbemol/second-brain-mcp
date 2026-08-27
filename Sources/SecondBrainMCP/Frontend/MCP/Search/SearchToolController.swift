import Foundation
import MCP

/// Decodes and dispatches the one public read-only search tool.
struct SearchToolController: Sendable {
    private let search: any VaultSearchService

    init(search: any VaultSearchService) {
        self.search = search
    }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard params.name == SearchToolDefinition.name else {
            return SearchToolResultMapper.failure("Unknown tool: \(params.name)")
        }

        let request: VaultSearchRequest
        do {
            request = try SearchToolRequestDecoder.decode(params)
        } catch let error as SearchToolRequestDecoder.DecodingError {
            return SearchToolResultMapper.failure(error.description)
        } catch {
            return SearchToolResultMapper.failure("Invalid search request")
        }

        do {
            let response = try await search.search(request)
            try Task.checkCancellation()
            return try SearchToolResultMapper.success(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VaultSearchRequestError {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(error.description)
        } catch {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(
                Self.failureMessage(for: error, in: request.location)
            )
        }
    }

    private static func failureMessage(
        for error: Error,
        in location: VaultArea
    ) -> String {
        let detail: String
        switch error {
        case let error as PathValidationError:
            detail = error.callerSafeDescription
        case let error as FileRoutingError:
            detail = error.callerSafeDescription
        case let error as VaultFileInspector.InspectionError:
            detail = error.callerSafeDescription
        case let error as FileResourcePolicy.Violation:
            detail = error.callerSafeDescription
        case PDFReadError.busy:
            detail = PDFReadError.busy.callerSafeDescription
        case let error as VaultAccessCoordinator.CapacityExceeded:
            detail = error.description
        default:
            detail = "Unexpected vault read error"
        }
        return "Search failed while reading \(location.rawValue)/: \(detail)"
    }
}

/// Strict MCP adapter for bounded criteria-free vault browsing.
struct ListFilesToolController: Sendable {
    private let listing: any FileListingService

    init(listing: any FileListingService) {
        self.listing = listing
    }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard params.name == ListFilesToolDefinition.name else {
            return ToolFailureProjection.rejected("Unknown tool: choose a tool returned by tools/list")
        }
        let request: ListFilesRequest
        do {
            request = try decode(params)
        } catch let error as DecodingError {
            return ToolFailureProjection.rejected(error.description)
        } catch {
            return ToolFailureProjection.rejected("Invalid list request")
        }
        do {
            let response = try await listing.list(request)
            try Task.checkCancellation()
            return success(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return ToolFailureProjection.operation(
                error, state: .readOnly,
                fallback: "List failed while reading \(request.area.rawValue)/"
            )
        }
    }

    private enum DecodingError: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    private func decode(_ params: CallTool.Parameters) throws -> ListFilesRequest {
        let values = params.arguments ?? [:]
        let allowed = Set([
            "area", "directory", "recursive", "formats", "limit", "cursor",
        ])
        if values.keys.contains(where: { !allowed.contains($0) }) {
            throw DecodingError.invalid("List request contains an unknown parameter")
        }
        guard let areaValue = values["area"] else {
            throw DecodingError.invalid("Missing required parameter: area")
        }
        guard let areaString = areaValue.stringValue,
              let area = VaultArea(rawValue: areaString) else {
            throw DecodingError.invalid("Invalid area: expected notes or references")
        }
        let directory = try optionalString("directory", values: values)
        let cursor = try optionalString("cursor", values: values)
        let recursive: Bool
        if let value = values["recursive"] {
            guard let parsed = value.boolValue else {
                throw DecodingError.invalid("Invalid parameter 'recursive': expected boolean")
            }
            recursive = parsed
        } else {
            recursive = true
        }
        let limit: Int
        if let value = values["limit"] {
            guard let parsed = value.intValue else {
                throw DecodingError.invalid("Invalid parameter 'limit': expected integer")
            }
            limit = parsed
        } else {
            limit = FileListingRequestLimits.defaultResults
        }
        var formats: [FileFormat] = []
        if let value = values["formats"] {
            guard let items = value.arrayValue else {
                throw DecodingError.invalid("Invalid parameter 'formats': expected array of strings")
            }
            for (index, item) in items.enumerated() {
                guard let raw = item.stringValue,
                      let format = FileFormat(rawValue: raw) else {
                    throw DecodingError.invalid(
                        "Invalid format at index \(index): expected a registered concrete format"
                    )
                }
                formats.append(format)
            }
            guard Set(formats).count == formats.count else {
                throw DecodingError.invalid("formats must contain unique values")
            }
        }
        return ListFilesRequest(
            area: area,
            directory: directory,
            recursive: recursive,
            formats: formats,
            limit: limit,
            cursor: cursor
        )
    }

    private func optionalString(
        _ name: String,
        values: [String: Value]
    ) throws -> String? {
        guard let value = values[name] else { return nil }
        guard let parsed = value.stringValue else {
            throw DecodingError.invalid("Invalid parameter '\(name)': expected string")
        }
        return parsed
    }

    private func success(_ response: ListFilesResult) -> CallTool.Result {
        let fileValues: [Value] = response.files.map { file in
            var values: [String: Value] = [
                "path": .string(file.path),
                "format": .string(file.format.rawValue),
                "byte_count": .int(file.byteCount),
            ]
            if let modified = file.modifiedAt {
                values["modified_at"] = .string(modified)
            }
            return .object(values)
        }
        var structured: [String: Value] = ["files": .array(fileValues)]
        if let cursor = response.nextCursor {
            structured["next_cursor"] = .string(cursor)
        }
        var textObject: [String: Any] = [
            "files": response.files.map { file -> [String: Any] in
                var values: [String: Any] = [
                    "path": file.path,
                    "format": file.format.rawValue,
                    "byte_count": file.byteCount,
                ]
                if let modified = file.modifiedAt {
                    values["modified_at"] = modified
                }
                return values
            },
        ]
        if let cursor = response.nextCursor {
            textObject["next_cursor"] = cursor
        }
        let text: String
        if JSONSerialization.isValidJSONObject(textObject),
           let data = try? JSONSerialization.data(
               withJSONObject: textObject,
               options: [.sortedKeys]
           ) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = "{\"files\":[]}"
        }
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: .object(structured)
        )
    }
}
