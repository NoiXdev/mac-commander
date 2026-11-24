import Testing

@testable import MacCommanderCore

@Suite struct RowSizeTests {
    @Test func metrics() {
        #expect(RowSize.compact.rowHeight == 20)
        #expect(RowSize.compact.iconSize == 16)
        #expect(RowSize.regular.rowHeight == 24)
        #expect(RowSize.regular.iconSize == 16)
        #expect(RowSize.large.rowHeight == 36)
        #expect(RowSize.large.iconSize == 32)
    }

    @Test(.english) func titles() {
        #expect(RowSize.allCases.map(\.title) == ["Compact", "Default", "Large"])
    }

    @Test func allCasesInOrder() {
        #expect(RowSize.allCases == [.compact, .regular, .large])
    }

    @Test func scrollOffsetKeepsTheTopRow() {
        // Row 10 is 6 pt past the top at 24 pt rows; at 36 pt it is 9 pt past (same fraction of the row).
        #expect(RowSize.scrollOffset(246, topInset: 0, from: 24, to: 36) == 369)
        #expect(RowSize.scrollOffset(369, topInset: 0, from: 36, to: 24) == 246)
    }

    @Test func scrollOffsetAccountsForTheTopInset() {
        // The visible area starts below a 52 pt inset: the row there stays there.
        #expect(RowSize.scrollOffset(240 - 52, topInset: 52, from: 24, to: 20) == 200 - 52)
        // Scrolled to the very top (offset -inset) stays at the top.
        #expect(RowSize.scrollOffset(-52, topInset: 52, from: 24, to: 36) == -52)
    }

    @Test func scrollOffsetWithoutRowHeightIsUnchanged() {
        #expect(RowSize.scrollOffset(100, topInset: 0, from: 0, to: 36) == 100)
    }
}
