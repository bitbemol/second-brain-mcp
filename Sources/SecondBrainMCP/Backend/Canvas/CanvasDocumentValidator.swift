import Foundation

/// Validates JSON Canvas documents.
///
/// The validator owns document-level invariants such as unique node identifiers
/// and valid edge references. ``CanvasDocument`` and its wire types own only JSON
/// decoding and field-level rules.
enum CanvasDocumentValidator {
    /// Structural and cross-reference errors in JSON Canvas data.
    enum ValidationError: Error, CustomStringConvertible {
        /// The payload is invalid JSON Canvas or omits a required field.
        case malformed(String)
        /// Two nodes declare the same identifier.
        case duplicateNodeID(String)
        /// An edge refers to a node identifier that is not present.
        case danglingEdge(edge: String, missingNode: String)

        /// Human-readable validation failure suitable for an MCP error response.
        var description: String {
            switch self {
            case .malformed(let reason):
                return "Invalid canvas JSON: \(reason)"
            case .duplicateNodeID(let id):
                return "Duplicate node id: \(id)"
            case .danglingEdge(let edge, let node):
                return "Edge '\(edge)' references missing node: '\(node)'"
            }
        }
    }

    /// Validates canvas JSON, unique node identifiers, and edge references.
    ///
    /// - Parameter jsonData: Original JSON bytes. Validation does not normalize or
    ///   re-encode the input.
    /// - Throws: ``ValidationError`` on a schema or cross-reference violation.
    static func validate(jsonData: Data) throws {
        do {
            try JSONSyntaxValidator.validate(
                jsonData,
                rejectingDuplicateObjectKeys: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ValidationError.malformed(error.localizedDescription)
        }

        let document: CanvasDocument
        do {
            document = try JSONDecoder().decode(CanvasDocument.self, from: jsonData)
        } catch let error as DecodingError {
            throw ValidationError.malformed(CanvasDecodingErrorFormatter.describe(error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ValidationError.malformed(error.localizedDescription)
        }

        let nodeIDs = try validatedNodeIDs(in: document)
        try validateEdges(in: document, nodeIDs: nodeIDs)
    }

    /// Collects node identifiers while rejecting duplicates.
    private static func validatedNodeIDs(
        in document: CanvasDocument
    ) throws -> Set<String> {
        var identifiers = Set<String>()
        for node in document.nodes {
            guard identifiers.insert(node.id).inserted else {
                throw ValidationError.duplicateNodeID(node.id)
            }
        }
        return identifiers
    }

    /// Verifies that every edge endpoint names a decoded node.
    private static func validateEdges(
        in document: CanvasDocument,
        nodeIDs: Set<String>
    ) throws {
        for edge in document.edges {
            if !nodeIDs.contains(edge.fromNode) {
                throw ValidationError.danglingEdge(
                    edge: edge.id,
                    missingNode: edge.fromNode
                )
            }
            if !nodeIDs.contains(edge.toNode) {
                throw ValidationError.danglingEdge(
                    edge: edge.id,
                    missingNode: edge.toNode
                )
            }
        }
    }
}
