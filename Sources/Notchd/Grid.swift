import AppKit

/// Each width unit includes its share of the gap/divider between widgets.
/// A row occupies N × `unit` points minus the trailing gap, plus the outer padding.
struct Grid {
    let sizing: OpenNotchSize
    let contentPadding: CGFloat

    init(prefs: Prefs) {
        sizing = prefs.openNotchSize
        contentPadding = prefs.contentPadding
    }

    var unit: CGFloat { sizing == .compact ? 90 : 100 }
    /// Horizontal padding inside the open notch (both sides).
    var padding: CGFloat { 2 * contentPadding }
    var verticalPadding: CGFloat { contentPadding * 0.8 }
    var dividerPadding: CGFloat { sizing == .compact ? 8 : 14 }

    func gap(dividers: Bool) -> CGFloat {
        dividers ? 2 * dividerPadding + 1 : sizing == .compact ? 10 : 14
    }

    /// Three 26-point buttons and two 6-point gaps on each side of the physical camera housing
    /// (Home, Tray, Clipboard; keep awake, settings, lock).
    func minimumWidth(notchWidth: CGFloat) -> CGFloat {
        max(sizing == .compact ? 380 : 480, notchWidth + 20 + 2 * (90 + 14))
    }

    /// Point width of a widget spanning `units`.
    func width(units: Int, dividers: Bool) -> CGFloat {
        CGFloat(units) * unit - gap(dividers: dividers)
    }

    /// How many units fit on a screen: the open notch may cover up to 75% of its width.
    func maxUnits(screenWidth: CGFloat) -> Int {
        max(0, Int((screenWidth * 0.75 - padding) / unit))
    }

    /// Open notch width for `units` worth of widgets.
    func openWidth(units: Int, dividers: Bool, notchWidth: CGFloat = 0) -> CGFloat {
        max(minimumWidth(notchWidth: notchWidth), padding + CGFloat(units) * unit - gap(dividers: dividers))
    }

    func openHeight(headerHeight: CGFloat, showsTimer: Bool) -> CGFloat {
        // The timer wheels and Start button need more room than the media player and lists.
        let contentHeight: CGFloat = showsTimer ? 128 : 100
        let fittedHeight = headerHeight + 2 * verticalPadding + contentHeight
        return sizing == .compact ? fittedHeight : max(200, fittedHeight)
    }
}

struct NookLayout: Equatable {
    var shown: [WidgetKind] = []
    var hidden: [WidgetKind] = []
    var usedUnits = 0
    var maxUnits = 0

    /// Places enabled widgets in order; one that doesn't fit is hidden, later ones still get a chance.
    static func fit(_ slots: [Slot<WidgetKind>], maxUnits: Int) -> NookLayout {
        var layout = NookLayout(maxUnits: maxUnits)
        for slot in slots where slot.enabled {
            let units = slot.units
            if layout.usedUnits + units <= maxUnits {
                layout.shown.append(slot.kind)
                layout.usedUnits += units
            } else {
                layout.hidden.append(slot.kind)
            }
        }
        return layout
    }
}

extension WidgetKind {
    var defaultUnits: Int {
        ["media": 3, "calendar": 3, "todo": 2, "timer": 3, "notes": 3, "shortcuts": 2, "mirror": 2,
         "capture": 2, "pomodoro": 2, "stats": 2, "weather": 3, "colors": 2][rawValue]!
    }
    var unitRange: ClosedRange<Int> {
        ["media": 3...4, "calendar": 3...5, "todo": 2...4, "timer": 3...4, "notes": 2...5, "shortcuts": 2...5,
         "mirror": 2...3, "capture": 2...3, "pomodoro": 2...3, "stats": 2...4, "weather": 2...4, "colors": 2...3][rawValue]!
    }
}

extension Slot where Kind == WidgetKind {
    /// User-chosen width, clamped to what the widget supports.
    var units: Int {
        get { min(max(customUnits ?? kind.defaultUnits, kind.unitRange.lowerBound), kind.unitRange.upperBound) }
        set { customUnits = newValue }
    }
}
