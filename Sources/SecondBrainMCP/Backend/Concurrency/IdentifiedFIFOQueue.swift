/// FIFO storage with constant-time lookup for cancellation by stable identifier.
///
/// Removed entries leave tombstones in insertion order. Prefix advancement and
/// density-based compaction keep both dequeue work and retained storage bounded
/// without shifting the remaining queue on every removal.
struct IdentifiedFIFOQueue<ID: Hashable, Element> {
    private var order: [ID] = []
    private var elements: [ID: Element] = [:]
    private var head = 0

    var count: Int { elements.count }
    var isEmpty: Bool { elements.isEmpty }

    mutating func append(_ element: Element, id: ID) {
        precondition(elements[id] == nil)
        order.append(id)
        elements[id] = element
    }

    mutating func remove(id: ID) -> Element? {
        guard let removed = elements.removeValue(forKey: id) else {
            return nil
        }
        compactIfNeeded()
        return removed
    }

    mutating func first() -> Element? {
        discardRemovedPrefix()
        guard head < order.count else { return nil }
        return elements[order[head]]
    }

    mutating func popFirst() -> Element? {
        discardRemovedPrefix()
        guard head < order.count else { return nil }
        let id = order[head]
        head += 1
        let element = elements.removeValue(forKey: id)
        compactIfNeeded()
        return element
    }

    private mutating func discardRemovedPrefix() {
        while head < order.count, elements[order[head]] == nil {
            head += 1
        }
        compactIfNeeded()
    }

    private mutating func compactIfNeeded() {
        guard !elements.isEmpty else {
            order = []
            head = 0
            return
        }

        let retainedCount = order.count - head
        if head >= 1_024, head * 2 >= order.count {
            order = Array(order[head...])
            head = 0
        } else if retainedCount > max(elements.count * 2, 1_024) {
            order = order[head...].filter { elements[$0] != nil }
            head = 0
        }
    }
}
