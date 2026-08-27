import Foundation
import MCP

struct LinkQueryToolController: Sendable {
    private let links: any VaultLinkQueryService

    init(links: any VaultLinkQueryService) {
        self.links = links
    }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard params.name == LinkQueryToolDefinition.name else {
            return SearchToolResultMapper.failure("Unknown tool: \(params.name)")
        }
        let request: LinkQueryRequest
        do {
            request = try LinkQueryToolRequestDecoder.decode(params)
        } catch let error as LinkQueryToolRequestDecoder.DecodingError {
            return SearchToolResultMapper.failure(error.description)
        } catch {
            return SearchToolResultMapper.failure("Invalid link query")
        }

        do {
            let response = try await links.query(request)
            try Task.checkCancellation()
            return try LinkQueryToolResultMapper.success(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LinkQueryError {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(error.description)
        } catch let error as PathValidationError {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(error.description)
        } catch let error as FileRoutingError {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(error.description)
        } catch let error as FileResourcePolicy.Violation {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(error.description)
        } catch let error as VaultAccessCoordinator.CapacityExceeded {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(error.description)
        } catch {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(
                "Link query failed while reading the vault"
            )
        }
    }
}
