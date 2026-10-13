import CoreGraphics
@testable import Notchd
import Testing

@Test func nookLayoutFit() {
    let slots: [Slot<WidgetKind>] = [
        Slot(kind: .media), Slot(kind: .timer), Slot(kind: .calendar), Slot(kind: .todo, enabled: false),
    ]
    // 3 + 3 + 2 = 8U
    #expect(NookLayout.fit(slots, maxUnits: 12) == NookLayout(shown: [.media, .timer, .calendar], usedUnits: 8, maxUnits: 12))
    // Timer (3U) doesn't fit after media in 5U, calendar (2U) still does.
    #expect(NookLayout.fit(slots, maxUnits: 5) == NookLayout(shown: [.media, .calendar], hidden: [.timer], usedUnits: 5, maxUnits: 5))

    var wide = slots
    wide[0].units = 4
    #expect(NookLayout.fit(wide, maxUnits: 12).usedUnits == 9)
    wide[0].units = 99  // clamped to the widget's range
    #expect(wide[0].units == WidgetKind.media.unitRange.upperBound)
}

@Test func gridWidths() {
    // N units take exactly N × unit points, dividers included.
    let dividers = true
    let parts = Grid.width(units: 3, dividers: dividers) + Grid.width(units: 2, dividers: dividers) + Grid.gap(dividers: dividers)
    #expect(parts == 5 * Grid.unit - Grid.gap(dividers: dividers))
    #expect(Grid.openWidth(units: 7, dividers: true) == Grid.padding + CGFloat(671))  // 700 - 29 trailing gap
    #expect(Grid.openWidth(units: 1, dividers: true) == Grid.minWidth)
    #expect(Grid.maxUnits(screenWidth: 1728) == 12)
}
