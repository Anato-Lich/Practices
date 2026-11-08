/// A browser's back and forward: `visit` a place, `back` and `forward` move between the visited
/// ones. A new visit drops what was ahead; the same place twice in a row is one entry.
public struct NavigationHistory<Entry: Equatable>: Equatable {
    public private(set) var current: Entry?
    public private(set) var backStack: [Entry] = []
    public private(set) var forwardStack: [Entry] = []
    public let limit: Int

    public init(limit: Int = 100) { self.limit = limit }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public mutating func visit(_ entry: Entry) {
        guard entry != current else { return }
        if let current { backStack.append(current) }
        if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        current = entry
        forwardStack = []
    }

    /// The place to show, or nil when there is nothing behind.
    public mutating func back() -> Entry? {
        guard let entry = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = entry
        return entry
    }

    public mutating func forward() -> Entry? {
        guard let entry = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = entry
        return entry
    }
}
