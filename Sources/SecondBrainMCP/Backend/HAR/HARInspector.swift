import Foundation

/// Validates required HTTP Archive structure and derives traffic summary facts.
enum HARInspector {
    /// Errors produced while validating the minimum required HAR structure.
    enum InspectionError: Error, CustomStringConvertible, CallerSafeError, Sendable {
        /// The payload cannot be decoded as a top-level JSON object.
        case invalidJSON
        /// The JSON object is missing a required HAR field or field type.
        case invalidStructure(String)

        var callerSafeDescription: String {
            switch self {
            case .invalidJSON:
                "HAR input must be valid, duplicate-key-free JSON with a top-level log object."
            case .invalidStructure:
                "Invalid HAR structure: require log.version, log.creator.name, and log.entries with valid request, response, and timing fields."
            }
        }

        /// Human-readable archive validation failure.
        var description: String {
            switch self {
            case .invalidJSON:
                return "HAR input is not valid JSON"
            case .invalidStructure(let reason):
                return "Invalid HAR structure: \(reason)"
            }
        }
    }

    /// Validates HAR bytes and projects the facts needed by read summaries.
    ///
    /// - Parameter data: Original HTTP Archive JSON bytes.
    /// - Returns: Validated archive metadata and aggregate traffic counts.
    /// - Throws: ``InspectionError`` when required archive structure is absent.
    static func inspect(data: Data) throws -> HARInspection {
        let document: HARDocument
        do {
            document = try JSONDecoder().decode(HARDocument.self, from: data)
        } catch {
            throw InspectionError.invalidJSON
        }

        guard let log = document.log else {
            throw InspectionError.invalidStructure("missing top-level log object")
        }
        guard let version = log.version, !version.isEmpty else {
            throw InspectionError.invalidStructure("missing log.version")
        }
        guard let creatorName = log.creator?.name, !creatorName.isEmpty else {
            throw InspectionError.invalidStructure("missing log.creator.name")
        }
        guard let entries = log.entries else {
            throw InspectionError.invalidStructure("missing log.entries array")
        }

        var methods: [String: Int] = [:]
        var statuses: [Int: Int] = [:]
        var hosts = Set<String>()
        var totalTime = 0.0

        for (index, entry) in entries.enumerated() {
            let entryNumber = index + 1
            guard let method = entry.request?.method, !method.isEmpty else {
                throw InspectionError.invalidStructure(
                    "entry \(entryNumber) is missing request.method"
                )
            }
            guard let requestURL = entry.request?.url, !requestURL.isEmpty else {
                throw InspectionError.invalidStructure(
                    "entry \(entryNumber) is missing request.url"
                )
            }
            guard let parsedURL = URL(string: requestURL),
                  let scheme = parsedURL.scheme, !scheme.isEmpty,
                  let host = parsedURL.host, !host.isEmpty else {
                throw InspectionError.invalidStructure(
                    "entry \(entryNumber) has an invalid request.url"
                )
            }
            guard let status = entry.response?.status,
                  (0...999).contains(status) else {
                throw InspectionError.invalidStructure(
                    "entry \(entryNumber) has an invalid response.status"
                )
            }
            guard let time = entry.time, time.isFinite, time >= 0 else {
                throw InspectionError.invalidStructure(
                    "entry \(entryNumber) has an invalid time"
                )
            }

            methods[method, default: 0] += 1
            hosts.insert(host.lowercased())
            statuses[status, default: 0] += 1
            totalTime += time
            guard totalTime.isFinite else {
                throw InspectionError.invalidStructure(
                    "entry timing total exceeds the supported numeric range"
                )
            }
        }

        return HARInspection(
            version: version,
            creatorName: creatorName,
            entryCount: entries.count,
            hostCount: hosts.count,
            totalTimeMilliseconds: totalTime,
            methods: methods,
            statuses: statuses
        )
    }
}
