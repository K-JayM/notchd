import AppKit
import SwiftUI

extension Animation {
    /// Opening overshoots a little, like the Dynamic Island.
    static let notchOpen = Animation.spring(response: 0.42, dampingFraction: 0.68)
    static let notchClose = Animation.spring(response: 0.36, dampingFraction: 0.88)
    static let notchHover = Animation.spring(response: 0.3, dampingFraction: 0.55)
}

enum Haptics {
    static func tap() {
        guard !Settings.shared.prefs.disableHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// Size of the camera housing, nil on screens without a notch.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }
}

@Observable
final class NotchModel {
    enum State { case closed, open }
    enum Tab { case nook, tray }

    var state: State = .closed
    var tab: Tab = .nook
    var hovering = false
    var dropping = false   // a file drag is happening over the notch
    var locked = false
    var typing = false

    let hasNotch: Bool
    /// Size of the shape when nothing is going on.
    let closedSize: CGSize

    static let openHeight: CGFloat = 200

    /// Widest the open notch may get on this screen, in units.
    let maxUnits: Int
    let displayID: CGDirectDisplayID

    /// Which widgets fit on this screen, in the user's order.
    var layout: NookLayout { NookLayout.fit(Settings.shared.prefs.widgets, maxUnits: maxUnits) }

    /// The open notch is exactly as wide as the widgets it shows.
    var openSize: CGSize {
        CGSize(width: Grid.openWidth(units: layout.usedUnits, dividers: Settings.shared.prefs.showDividers),
               height: Self.openHeight)
    }
    static let activitySide: CGFloat = 46

    init(screen: NSScreen) {
        let notch = screen.notchSize
        let prefs = Settings.shared.prefs
        hasNotch = notch != nil
        maxUnits = Grid.maxUnits(screenWidth: screen.frame.width)
        displayID = screen.displayID
        closedSize = notch.map {
            CGSize(width: $0.width + prefs.notchWidthFineTune, height: $0.height + prefs.notchHeightFineTune)
        } ?? CGSize(width: prefs.handleWidth, height: prefs.handleHeight)
    }

    var isOpen: Bool { state == .open }

    /// "Show in fullscreen": hide the whole notch while an app is fullscreen on this screen.
    var hiddenByFullscreen: Bool {
        guard FullscreenMonitor.shared.isFullscreen(displayID) else { return false }
        switch Settings.shared.prefs.showInFullscreen {
        case .allMonitors: return false
        case .notchedScreens: return !hasNotch
        case .never: return true
        }
    }

    /// Body size (between the two "ears") for the current state.
    func size(activity: LiveActivity?) -> CGSize {
        if isOpen { return openSize }
        if activity != nil {
            if isPeeking {
                return CGSize(width: closedSize.width + 2 * Self.activitySide + Self.peekExtraWidth,
                              height: activityRowHeight + Self.peekHeight)
            }
            return CGSize(width: closedSize.width + 2 * Self.activitySide + (hovering ? 8 : 0),
                          height: activityRowHeight + (hovering ? 3 : 0))
        }
        if hovering {
            return hasNotch
                ? CGSize(width: closedSize.width + 16, height: closedSize.height + 4)
                : CGSize(width: closedSize.width + 30, height: 22)
        }
        return closedSize
    }

    static let peekHeight: CGFloat = 26
    static let peekExtraWidth: CGFloat = 70

    var activityRowHeight: CGFloat { max(closedSize.height, 30) }

    /// Glance: hovering a live activity (or a song change) slides a line of info out under it.
    var isPeeking: Bool {
        Settings.shared.prefs.enableGlance && (hovering || ActivityCenter.shared.autoPeek)
    }

    func radii(activity: LiveActivity?) -> (top: CGFloat, bottom: CGFloat) {
        if isOpen { return (14, 26) }
        if activity != nil, isPeeking { return (10, 18) }
        if activity != nil || hovering { return (8, 13) }
        return hasNotch ? (6, 10) : (3, 4)
    }

    func open() {
        guard !isOpen, Settings.shared.prefs.nookEnabled || dropping else { return }
        withAnimation(.notchOpen) { state = .open }
        Haptics.tap()
    }

    func close() {
        guard isOpen else { return }
        withAnimation(.notchClose) {
            state = .closed
            dropping = false
            typing = false
        }
    }

    func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        withAnimation(.notchHover) { hovering = value }
    }
}

// ponytail: the macOS 27 SDK turns `@State` into a macro whose plugin only ships with Xcode.
// Spelling the property wrapper through an alias keeps Command Line Tools builds working; drop when building with Xcode.
typealias Local<Value> = SwiftUI.State<Value>
