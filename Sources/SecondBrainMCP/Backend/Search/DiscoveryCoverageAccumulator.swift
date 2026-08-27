import Foundation

/// Stores exact failure counts but only a bounded sample of complete identifiers.
struct DiscoveryCoverageAccumulator {
    static let maximumSamples = 3
    static let maximumEncodedBytes = 2_048
    private static let maximumFormatCounts = Dictionary(
        uniqueKeysWithValues: FileFormat.allCases.map { ($0.rawValue, Int.max) }
    )
    private var failedFiles = 0
    private var failedByFormat: [String: Int] = [:]
    private var samples: [DiscoveryCoverage.Failure] = []
    private var truncated = false

    mutating func record(path: String, reason: DiscoveryCoverage.Reason, format: FileFormat? = nil) {
        failedFiles += 1
        if let format { failedByFormat[format.rawValue, default: 0] += 1 }
        guard samples.count < Self.maximumSamples else {
            truncated = true
            return
        }
        let proposed = samples + [.init(path: path, reason: reason)]
        // Reserve enough digits for any future count without growing the response.
        let worstCase = DiscoveryCoverage(
            complete: false, failedFiles: Int.max, samples: proposed, samplesTruncated: false,
            failedByFormat: failedByFormat.isEmpty ? nil : Self.maximumFormatCounts
        )
        guard let bytes = try? JSONEncoder().encode(worstCase),
              bytes.count <= Self.maximumEncodedBytes else {
            truncated = true
            return
        }
        samples = proposed
    }

    var value: DiscoveryCoverage {
        failedFiles == 0 ? .full : DiscoveryCoverage(
            complete: false, failedFiles: failedFiles,
            samples: samples, samplesTruncated: truncated,
            failedByFormat: failedByFormat.isEmpty ? nil : failedByFormat
        )
    }
}
