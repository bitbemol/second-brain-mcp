/// Exact structural kind selected for one atomic notes path move.
enum PathMoveKind: String, CaseIterable, Codable, Sendable {
    case file
    case directory
}

/// One atomic rename under `notes/` with kind-specific safety inputs.
///
/// Associated cases prevent backend callers from constructing a file move without
/// both its concrete format and exact expected revision. Directory moves retain
/// their structural subtree contract without irrelevant file parameters.
enum MovePathRequest: Equatable, Sendable {
    static let operationIdentifier = "move_path"

    case file(
        sourcePath: String,
        destinationPath: String,
        format: FileFormat,
        expectedRevision: FileRevision
    )
    case directory(
        sourcePath: String,
        destinationPath: String
    )

    var kind: PathMoveKind {
        switch self {
        case .file: .file
        case .directory: .directory
        }
    }

    var sourcePath: String {
        switch self {
        case .file(let sourcePath, _, _, _),
             .directory(let sourcePath, _):
            sourcePath
        }
    }

    var destinationPath: String {
        switch self {
        case .file(_, let destinationPath, _, _),
             .directory(_, let destinationPath):
            destinationPath
        }
    }
}

/// Public request limits for path moves.
enum PathMoveRequestLimits {
    /// Paths remain well below filesystem and transport amplification ceilings.
    static let maximumPathBytes = 4 * 1_024
}
