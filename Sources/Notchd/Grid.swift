import AppKit

/// The nook is laid out in units (U). One U includes its share of the gap/divider between widgets,
/// so N units always take exactly N × `unit` points, whatever the widget mix.
enum Grid {
    static let unit: CGFloat = 100
    /// Horizontal padding inside the open notch (both sides).
    static var padding: CGFloat { 2 * Settings.shared.prefs.contentPadding }
    static let minWidth: CGFloat = 480 // the header (tabs + notch + buttons) needs this much

    static func gap(dividers: Bool) -> CGFloat { dividers ? 29 : 14 }

    /// Point width of a widget spanning `units`.
    static func width(units: Int, dividers: Bool) -> CGFloat {
        CGFloat(units) * unit - gap(dividers: dividers)
    }

    /// How many units fit on a screen: the open notch may cover up to 75% of its width.
    static func maxUnits(screenWidth: CGFloat) -> Int {
        Int((screenWidth * 0.75 - padding) / unit)
    }

    /// Open notch width for `units` worth of widgets.
    static func openWidth(units: Int, dividers: Bool) -> CGFloat {
        max(minWidth, padding + CGFloat(units) * unit - gap(dividers: dividers))
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
    var defaultUnits: Int { ["media": 3, "calendar": 2, "todo": 2, "timer": 3][rawValue]! }
    var unitRange: ClosedRange<Int> { ["media": 3...4, "calendar": 2...4, "todo": 2...4, "timer": 3...4][rawValue]! }
}

extension Slot where Kind == WidgetKind {
    /// User-chosen width, clamped to what the widget supports.
    var units: Int {
        get { min(max(customUnits ?? kind.defaultUnits, kind.unitRange.lowerBound), kind.unitRange.upperBound) }
        set { customUnits = newValue }
    }
}
