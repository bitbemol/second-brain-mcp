import Testing
@testable import SecondBrainMCP

@Suite("Bounded ranked selection")
struct BoundedRankedSelectionTests {
    @Test("Seeded heap selection matches a simple bounded reference")
    func randomizedDifferential() {
        var random = SeededRandom(state: 0x5EED_CAFE_D15C_A11E)
        var actual = BoundedRankedSelection()
        var expected = ReferenceSelection()
        let maximumCount = 17
        let maximumPerPath = 3

        for step in 0..<5_000 {
            let candidate: RankedSearchResult
            if step.isMultiple(of: 3) {
                // Replacing one identity thousands of times forces lazy stale
                // heap entries and multiple bounded heap rebuilds.
                candidate = makeCandidate(
                    path: "notes/anchor.md",
                    lineStart: 1,
                    lineEnd: 1,
                    physicalPage: nil,
                    heading: "anchor",
                    score: Double(step * 100)
                )
            } else {
                let path = "notes/p\(random.next(upperBound: 9)).md"
                let line = random.next(upperBound: 11) + 1
                candidate = makeCandidate(
                    path: path,
                    lineStart: line,
                    lineEnd: line + random.next(upperBound: 3),
                    physicalPage: random.next(upperBound: 4) == 0
                        ? nil : random.next(upperBound: 4) + 1,
                    heading: random.next(upperBound: 3) == 0
                        ? "h\(random.next(upperBound: 4))" : nil,
                    // A deliberately small range creates exact ranking ties.
                    score: Double(random.next(upperBound: 31) * 1_000)
                )
            }

            let actualAdmission = actual.admit(
                candidate,
                maximumCount: maximumCount,
                maximumPerPath: maximumPerPath
            ) {}
            let expectedAdmission = expected.admit(
                candidate,
                maximumCount: maximumCount,
                maximumPerPath: maximumPerPath
            )

            #expect(actualAdmission == expectedAdmission)
            #expect(snapshot(actual.values) == snapshot(expected.values))
        }
    }

    @Test("One key orders score path page and line consistently")
    func deterministicOrderingKey() {
        let candidates = [
            makeCandidate(path: "notes/b.md", lineStart: 1, score: 10),
            makeCandidate(path: "notes/a.md", lineStart: 5, score: 10),
            makeCandidate(
                path: "notes/a.md",
                lineStart: 2,
                physicalPage: 2,
                score: 10
            ),
            makeCandidate(
                path: "notes/a.md",
                lineStart: 8,
                physicalPage: 1,
                score: 10
            ),
            makeCandidate(path: "notes/z.md", lineStart: 9, score: 11),
        ].sorted { BoundedRankedSelection.isBetter($0, than: $1) }

        #expect(candidates.map { Snapshot($0) } == [
            Snapshot(
                path: "notes/z.md", lineStart: 9, lineEnd: 9,
                physicalPage: nil, heading: nil, score: 11
            ),
            Snapshot(
                path: "notes/a.md", lineStart: 5, lineEnd: 5,
                physicalPage: nil, heading: nil, score: 10
            ),
            Snapshot(
                path: "notes/a.md", lineStart: 8, lineEnd: 8,
                physicalPage: 1, heading: nil, score: 10
            ),
            Snapshot(
                path: "notes/a.md", lineStart: 2, lineEnd: 2,
                physicalPage: 2, heading: nil, score: 10
            ),
            Snapshot(
                path: "notes/b.md", lineStart: 1, lineEnd: 1,
                physicalPage: nil, heading: nil, score: 10
            ),
        ])
    }

    private func makeCandidate(
        path: String,
        lineStart: Int,
        lineEnd: Int? = nil,
        physicalPage: Int? = nil,
        heading: String? = nil,
        score: Double
    ) -> RankedSearchResult {
        RankedSearchResult(
            result: VaultSearchResult(
                path: path,
                format: physicalPage == nil ? .markdown : .pdf,
                title: path,
                heading: heading,
                location: nil,
                snippet: "safe",
                lineStart: lineStart,
                lineEnd: lineEnd ?? lineStart,
                matchedFields: [.content],
                relevance: min(score / 1_000_000, 1),
                termCoverage: 1,
                physicalPage: physicalPage
            ),
            score: score,
            hasWholeLiteral: false
        )
    }

    private func snapshot(_ values: [RankedSearchResult]) -> [Snapshot] {
        values.map(Snapshot.init).sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.lineStart != $1.lineStart { return $0.lineStart < $1.lineStart }
            if $0.lineEnd != $1.lineEnd { return $0.lineEnd < $1.lineEnd }
            if $0.physicalPage != $1.physicalPage {
                return ($0.physicalPage ?? 0) < ($1.physicalPage ?? 0)
            }
            if $0.heading != $1.heading {
                return ($0.heading ?? "") < ($1.heading ?? "")
            }
            return $0.score < $1.score
        }
    }

    private struct Snapshot: Equatable {
        let path: String
        let lineStart: Int
        let lineEnd: Int
        let physicalPage: Int?
        let heading: String?
        let score: Double

        init(_ candidate: RankedSearchResult) {
            path = candidate.result.path
            lineStart = candidate.result.lineStart
            lineEnd = candidate.result.lineEnd
            physicalPage = candidate.result.physicalPage
            heading = candidate.result.heading
            score = candidate.score
        }

        init(
            path: String,
            lineStart: Int,
            lineEnd: Int,
            physicalPage: Int?,
            heading: String?,
            score: Double
        ) {
            self.path = path
            self.lineStart = lineStart
            self.lineEnd = lineEnd
            self.physicalPage = physicalPage
            self.heading = heading
            self.score = score
        }
    }

    private struct ReferenceSelection {
        var values: [RankedSearchResult] = []

        mutating func admit(
            _ candidate: RankedSearchResult,
            maximumCount: Int,
            maximumPerPath: Int
        ) -> BoundedRankedSelection.Admission {
            if let existing = values.firstIndex(where: {
                Identity($0.result) == Identity(candidate.result)
            }) {
                guard BoundedRankedSelection.isBetter(
                    candidate,
                    than: values[existing]
                ) else {
                    return .rejected
                }
                values[existing] = candidate
                return .replaced
            }

            guard maximumPerPath > 0 else { return .rejected }
            let samePath = values.indices.filter {
                values[$0].result.path == candidate.result.path
            }
            if samePath.count >= maximumPerPath {
                let worst = worstIndex(in: samePath)
                guard BoundedRankedSelection.isBetter(
                    candidate,
                    than: values[worst]
                ) else {
                    return .rejected
                }
                values[worst] = candidate
                return .replaced
            }

            guard maximumCount > 0 else { return .rejectedAtCapacity }
            if values.count < maximumCount {
                values.append(candidate)
                return .inserted
            }
            let worst = worstIndex(in: Array(values.indices))
            guard BoundedRankedSelection.isBetter(
                candidate,
                than: values[worst]
            ) else {
                return .rejectedAtCapacity
            }
            values[worst] = candidate
            return .replacedAtCapacity
        }

        private func worstIndex(in indices: [Int]) -> Int {
            indices.min { lhs, rhs in
                let lhsKey = BoundedRankedSelection.RankingKey(values[lhs])
                let rhsKey = BoundedRankedSelection.RankingKey(values[rhs])
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                return lhs < rhs
            }!
        }
    }

    private struct Identity: Equatable {
        let path: String
        let lineStart: Int
        let lineEnd: Int
        let heading: String?
        let physicalPage: Int?

        init(_ result: VaultSearchResult) {
            path = result.path
            lineStart = result.lineStart
            lineEnd = result.lineEnd
            heading = result.heading
            physicalPage = result.physicalPage
        }
    }

    private struct SeededRandom {
        var state: UInt64

        mutating func next(upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state % UInt64(upperBound))
        }
    }
}
