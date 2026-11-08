import Testing
@testable import PracticesCore

@Suite struct NavigationHistoryTests {
    @Test func backAndForward() {
        var h = NavigationHistory<String>()
        #expect(!h.canGoBack && !h.canGoForward)
        h.visit("a"); h.visit("b"); h.visit("c")
        #expect(h.back() == "b")
        #expect(h.back() == "a")
        #expect(h.back() == nil && h.current == "a")
        #expect(h.forward() == "b")
        #expect(h.forward() == "c")
        #expect(h.forward() == nil && h.current == "c")
    }

    @Test func newVisitClearsForward() {
        var h = NavigationHistory<String>()
        h.visit("a"); h.visit("b")
        _ = h.back()
        h.visit("x")
        #expect(!h.canGoForward)
        #expect(h.backStack == ["a"] && h.current == "x")
    }

    @Test func sameEntryTwiceIsOne() {
        var h = NavigationHistory<String>()
        h.visit("a"); h.visit("a"); h.visit("b"); h.visit("b")
        #expect(h.backStack == ["a"])
        // Visiting the place already shown keeps what is ahead.
        _ = h.back()
        h.visit("a")
        #expect(h.forwardStack == ["b"])
    }

    @Test func capKeepsTheLatest() {
        var h = NavigationHistory<Int>(limit: 3)
        for i in 0..<10 { h.visit(i) }
        #expect(h.backStack == [6, 7, 8] && h.current == 9)
    }
}
