import Foundation

/// One internal candidate with the immutable facts needed by bounded ranking.
struct RankedSearchResult: Sendable {
    let result: VaultSearchResult
    let score: Double
    let hasWholeLiteral: Bool
}

/// Cohesive bounded top-K selection with identity and per-path replacement.
///
/// A single comparable key defines both heap eviction and final response order.
/// Larger keys are better; the heap root is therefore the current worst value.
struct BoundedRankedSelection {
    struct RankingKey: Comparable, Sendable {
        let score: Double
        let path: String
        let physicalPage: Int?
        let lineStart: Int
        let lineEnd: Int
        let nodeID: String?
        let field: String?
        let heading: String?

        init(_ candidate: RankedSearchResult) {
            score = candidate.score
            path = candidate.result.path
            physicalPage = candidate.result.physicalPage
            lineStart = candidate.result.lineStart
            lineEnd = candidate.result.lineEnd
            nodeID = candidate.result.location?.nodeID
            field = candidate.result.location?.field
            heading = candidate.result.heading
        }

        static func < (lhs: RankingKey, rhs: RankingKey) -> Bool {
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.path != rhs.path { return lhs.path > rhs.path }
            if lhs.physicalPage != rhs.physicalPage {
                return (lhs.physicalPage ?? 0) > (rhs.physicalPage ?? 0)
            }
            if lhs.lineStart != rhs.lineStart {
                return lhs.lineStart > rhs.lineStart
            }
            if lhs.lineEnd != rhs.lineEnd { return lhs.lineEnd > rhs.lineEnd }
            if lhs.nodeID != rhs.nodeID {
                return (lhs.nodeID ?? "") > (rhs.nodeID ?? "")
            }
            if lhs.field != rhs.field {
                return (lhs.field ?? "") > (rhs.field ?? "")
            }
            return (lhs.heading ?? "") > (rhs.heading ?? "")
        }
    }

    enum Admission: Equatable, Sendable {
        case rejected
        case inserted
        case replaced
        case rejectedAtCapacity
        case replacedAtCapacity

        var encounteredGlobalLimit: Bool {
            self == .rejectedAtCapacity || self == .replacedAtCapacity
        }
    }

    private struct ResultIdentity: Hashable {
        let path: String
        let lineStart: Int
        let lineEnd: Int
        let nodeID: String?
        let field: String?
        let heading: String?
        let physicalPage: Int?

        init(_ result: VaultSearchResult) {
            path = result.path
            lineStart = result.lineStart
            lineEnd = result.lineEnd
            nodeID = result.location?.nodeID
            field = result.location?.field
            heading = result.heading
            physicalPage = result.physicalPage
        }
    }

    private struct HeapEntry {
        let index: Int
        let generation: UInt64
        let key: RankingKey
    }

    private(set) var values: [RankedSearchResult] = []
    private var indexByIdentity: [ResultIdentity: Int] = [:]
    private var indicesByPath: [String: Set<Int>] = [:]
    private var generations: [UInt64] = []
    private var worstHeap: [HeapEntry] = []

    /// Admits a candidate only after it can affect the bounded selection.
    /// Validation therefore retains the previous behavior of avoiding work for
    /// inferior duplicates and per-path overflow while still validating every
    /// candidate considered at the global boundary.
    mutating func admit(
        _ candidate: RankedSearchResult,
        maximumCount: Int,
        maximumPerPath: Int,
        validate: () throws -> Void
    ) rethrows -> Admission {
        let candidateIdentity = ResultIdentity(candidate.result)
        if let existing = indexByIdentity[candidateIdentity] {
            guard isBetter(candidate, than: values[existing]) else {
                return .rejected
            }
            try validate()
            replace(at: existing, with: candidate)
            return .replaced
        }

        guard maximumPerPath > 0 else { return .rejected }
        let samePath = indicesByPath[candidate.result.path, default: []]
        if samePath.count >= maximumPerPath {
            guard let worstForPath = worstIndex(in: samePath),
                  isBetter(candidate, than: values[worstForPath]) else {
                return .rejected
            }
            try validate()
            replace(at: worstForPath, with: candidate)
            return .replaced
        }

        try validate()
        guard maximumCount > 0 else { return .rejectedAtCapacity }
        if values.count < maximumCount {
            append(candidate)
            return .inserted
        }
        guard let worst = worstIndex(),
              isBetter(candidate, than: values[worst]) else {
            return .rejectedAtCapacity
        }
        replace(at: worst, with: candidate)
        return .replacedAtCapacity
    }

    static func isBetter(
        _ lhs: RankedSearchResult,
        than rhs: RankedSearchResult
    ) -> Bool {
        RankingKey(lhs) > RankingKey(rhs)
    }

    private func isBetter(
        _ lhs: RankedSearchResult,
        than rhs: RankedSearchResult
    ) -> Bool {
        Self.isBetter(lhs, than: rhs)
    }

    private func worstIndex(in indices: Set<Int>) -> Int? {
        indices.min { lhs, rhs in
            let lhsKey = RankingKey(values[lhs])
            let rhsKey = RankingKey(values[rhs])
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs < rhs
        }
    }

    private mutating func append(_ candidate: RankedSearchResult) {
        let index = values.count
        values.append(candidate)
        generations.append(0)
        indexByIdentity[ResultIdentity(candidate.result)] = index
        indicesByPath[candidate.result.path, default: []].insert(index)
        pushHeapEntry(index: index)
    }

    private mutating func replace(
        at index: Int,
        with candidate: RankedSearchResult
    ) {
        let removed = values[index]
        indexByIdentity.removeValue(forKey: ResultIdentity(removed.result))
        indicesByPath[removed.result.path]?.remove(index)
        if indicesByPath[removed.result.path]?.isEmpty == true {
            indicesByPath.removeValue(forKey: removed.result.path)
        }

        values[index] = candidate
        generations[index] &+= 1
        indexByIdentity[ResultIdentity(candidate.result)] = index
        indicesByPath[candidate.result.path, default: []].insert(index)
        pushHeapEntry(index: index)

        if worstHeap.count > max(values.count * 3, 1_024) {
            rebuildHeap()
        }
    }

    private mutating func worstIndex() -> Int? {
        while let first = worstHeap.first {
            if generations[first.index] == first.generation {
                return first.index
            }
            popHeapRoot()
        }
        return nil
    }

    private mutating func pushHeapEntry(index: Int) {
        worstHeap.append(HeapEntry(
            index: index,
            generation: generations[index],
            key: RankingKey(values[index])
        ))
        var child = worstHeap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heapEntryIsWorse(worstHeap[child], than: worstHeap[parent]) else {
                break
            }
            worstHeap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func popHeapRoot() {
        guard !worstHeap.isEmpty else { return }
        if worstHeap.count == 1 {
            worstHeap.removeLast()
            return
        }
        worstHeap[0] = worstHeap.removeLast()
        var parent = 0
        while true {
            let left = (parent * 2) + 1
            guard left < worstHeap.count else { return }
            let right = left + 1
            var worse = left
            if right < worstHeap.count,
               heapEntryIsWorse(worstHeap[right], than: worstHeap[left]) {
                worse = right
            }
            guard heapEntryIsWorse(worstHeap[worse], than: worstHeap[parent]) else {
                return
            }
            worstHeap.swapAt(parent, worse)
            parent = worse
        }
    }

    private mutating func rebuildHeap() {
        worstHeap.removeAll(keepingCapacity: true)
        for index in values.indices { pushHeapEntry(index: index) }
    }

    private func heapEntryIsWorse(_ lhs: HeapEntry, than rhs: HeapEntry) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        return lhs.index < rhs.index
    }
}
