// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Opened screenshots kept in memory and never on disk, most recently used
/// last, within a byte budget and a count. A list that scrolls back shows its
/// screenshots at once instead of opening each again, and the budget keeps a
/// long day from growing the window without end.
///
/// A value larger than a quarter of the budget is not kept, so one large
/// screenshot never pushes out every small one.
public struct ScreenshotMemoryCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public let byteLimit: Int
    public let countLimit: Int
    public private(set) var totalBytes = 0

    private struct Slot: Sendable {
        let value: Value
        let cost: Int
    }

    private var slots: [Key: Slot] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    public init(byteLimit: Int, countLimit: Int) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }

    public var count: Int { slots.count }

    /// The value kept for `key`, which becomes the most recently used.
    public mutating func value(for key: Key) -> Value? {
        guard let slot = slots[key] else { return nil }
        touch(key)
        return slot.value
    }

    /// Keep `value`, which costs `cost` bytes, dropping the least recently
    /// used values until the budget and the count hold. Returns whether it
    /// was kept.
    @discardableResult
    public mutating func insert(_ value: Value, cost: Int, for key: Key) -> Bool {
        removeValue(for: key)
        guard cost >= 0, countLimit > 0, cost <= byteLimit / 4 else { return false }
        while !order.isEmpty, totalBytes + cost > byteLimit || slots.count + 1 > countLimit {
            removeValue(for: order[0])
        }
        slots[key] = Slot(value: value, cost: cost)
        order.append(key)
        totalBytes += cost
        return true
    }

    public mutating func removeValue(for key: Key) {
        guard let slot = slots.removeValue(forKey: key) else { return }
        totalBytes -= slot.cost
        order.removeAll { $0 == key }
    }

    public mutating func removeAll() {
        slots.removeAll()
        order.removeAll()
        totalBytes = 0
    }

    private mutating func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}
