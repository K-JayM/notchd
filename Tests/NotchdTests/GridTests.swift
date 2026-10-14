import CoreGraphics
@testable import Notchd
import Testing

@Test func nookLayoutFit() {
    let slots: [Slot<WidgetKind>] = [
        Slot(kind: .media), Slot(kind: .timer), Slot(kind: .todo), Slot(kind: .calendar, enabled: false),
    ]
    // 3 + 3 + 2 = 8U
    #expect(NookLayout.fit(slots, maxUnits: 12) == NookLayout(shown: [.media, .timer, .todo], usedUnits: 8, maxUnits: 12))
    // Timer (3U) doesn't fit after media in 5U, the to-do list (2U) still does.
    #expect(NookLayout.fit(slots, maxUnits: 5) == NookLayout(shown: [.media, .todo], hidden: [.timer], usedUnits: 5, maxUnits: 5))

    var wide = slots
    wide[0].units = 4
    #expect(NookLayout.fit(wide, maxUnits: 12).usedUnits == 9)
    wide[0].units = 99  // clamped to the widget's range
    #expect(wide[0].units == WidgetKind.media.unitRange.upperBound)
}

@Test(arguments: OpenNotchSize.allCases, [false, true])
func gridWidths(sizing: OpenNotchSize, dividers: Bool) {
    var prefs = Prefs()
    prefs.openNotchSize = sizing
    let grid = Grid(prefs: prefs)
    let widths = prefs.widgets.filter(\.enabled).map { grid.width(units: $0.units, dividers: dividers) }
    let content = widths.reduce(0, +) + CGFloat(widths.count - 1) * grid.gap(dividers: dividers)
    let units = prefs.widgets.filter(\.enabled).reduce(0) { $0 + $1.units }
    #expect(grid.openWidth(units: units, dividers: dividers) == content + grid.padding)
    #expect(grid.openWidth(units: 1, dividers: dividers) >= 380)

    for screenWidth: CGFloat in [800, 1280, 1512, 1728] {
        for padding: CGFloat in [4, 12, 24] {
            prefs.contentPadding = padding
            let fitted = Grid(prefs: prefs)
            let units = fitted.maxUnits(screenWidth: screenWidth)
            #expect(fitted.openWidth(units: units, dividers: dividers) <= screenWidth * 0.75)
        }
    }
}

@Test func compactLayoutFitsControlsAndCameraHousing() {
    var prefs = Prefs()
    let compact = Grid(prefs: prefs)
    prefs.openNotchSize = .roomy
    let roomy = Grid(prefs: prefs)
    #expect(compact.openWidth(units: 7, dividers: true) < roomy.openWidth(units: 7, dividers: true))
    #expect(roomy.openWidth(units: 7, dividers: true) == 695)
    #expect(roomy.openHeight(headerHeight: 32, showsTimer: false) == 200)

    for headerHeight: CGFloat in [30, 32, 52] {
        let height = compact.openHeight(headerHeight: headerHeight, showsTimer: false)
        #expect(height < roomy.openHeight(headerHeight: headerHeight, showsTimer: false))
        #expect(height - headerHeight - 2 * compact.verticalPadding >= 99.9)
        let timerHeight = compact.openHeight(headerHeight: headerHeight, showsTimer: true)
        #expect(timerHeight - headerHeight - 2 * compact.verticalPadding >= 127.9)
    }
    for notchWidth: CGFloat in [0, 185, 240, 300] {
        let width = compact.openWidth(units: 0, dividers: true, notchWidth: notchWidth)
        let availablePerSide = (width - notchWidth - 20) / 2 - 14
        #expect(availablePerSide >= 58)
    }
}
