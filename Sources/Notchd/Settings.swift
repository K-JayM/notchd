import AppKit
import ServiceManagement
import SwiftUI

protocol SlotKind: Codable, Hashable, CaseIterable, Identifiable {
    var title: String { get }
    var icon: String { get }
    var defaultEnabled: Bool { get }
}

extension SlotKind {
    var defaultEnabled: Bool { true }
}

enum ActivityKind: String, SlotKind {
    // Default priority: short events first (they flash for a few seconds), long-lived ones after.
    case bluetooth, battery, timerExpired, updateAvailable, calendar, media, tray
    var id: Self { self }
    var title: String {
        ["media": "Media", "tray": "Tray", "calendar": "Calendar", "bluetooth": "Bluetooth",
         "battery": "Battery", "timerExpired": "Timer Done", "updateAvailable": "New Update"][rawValue]!
    }
    var icon: String {
        ["media": "music.note", "tray": "tray.fill", "calendar": "calendar", "bluetooth": "headphones",
         "battery": "bolt.fill", "timerExpired": "timer", "updateAvailable": "arrow.down.circle.fill"][rawValue]!
    }
}

enum WidgetKind: String, SlotKind {
    case media, calendar, todo, timer, capture
    var id: Self { self }
    var title: String {
        ["media": "Media Player", "calendar": "Calendar", "todo": "To-do List", "timer": "Timer", "capture": "Capture"][rawValue]!
    }
    var icon: String { ["media": "music.note", "calendar": "calendar", "todo": "checklist", "timer": "timer", "capture": "camera.viewfinder"][rawValue]! }
    /// Enabled by default: media, calendar, to-do and capture.
    var defaultEnabled: Bool { self != .timer }
}

enum FullscreenMode: String, Codable, CaseIterable, Identifiable {
    case allMonitors, notchedScreens, never
    var id: Self { self }
    var title: String { ["allMonitors": "All screens", "notchedScreens": "Screens with a notch", "never": "Never"][rawValue]! }
}

enum OpenNotchSize: String, Codable, CaseIterable, Identifiable {
    case compact, roomy
    var id: Self { self }
    var title: String { self == .compact ? "Compact" : "Roomy" }
}

enum MediaEffect: String, Codable, CaseIterable, Identifiable {
    case spectrograph, waves, vibratingCircle, gif
    var id: Self { self }
    var title: String {
        ["spectrograph": "Equalizer", "waves": "Wave", "vibratingCircle": "Pulse", "gif": "Your GIF"][rawValue]!
    }
}

/// An orderable, switchable entry (live activity or nook widget). Order = display priority.
struct Slot<Kind: SlotKind>: Codable, Equatable {
    var kind: Kind
    var enabled = true
    var customUnits: Int?  // widgets only: width in U, nil = default

    static var all: [Slot] { Kind.allCases.map { Slot(kind: $0, enabled: $0.defaultEnabled) } }

    /// Keeps the user's order and appends kinds added in newer versions.
    static func normalized(_ slots: [Slot]) -> [Slot] {
        slots + all.filter { new in !slots.contains { $0.kind == new.kind } }
    }
}

struct Prefs: Codable, Equatable {
    // General
    var alwaysOpenOnHover = false
    var disableHaptics = false
    var preventCloseWhenTyping = true
    var notchWidthFineTune = 0.0
    var notchHeightFineTune = 0.0
    var enableOnNonNotchScreens = true
    var transparentHandle = false
    var handleWidth = 184.0
    var handleHeight = 8.0
    var showInFullscreen = FullscreenMode.notchedScreens
    var lockWhileTyping = false
    var preferRoundButtons = true
    var translucentBackground = false
    var contentPadding = 12.0
    var demoMode = false
    var didShowWelcome = false
    var autoCheckUpdates = true
    // Gestures
    var allowGestures = true
    var gestureOpenClose = true
    var gestureControlMedia = true
    var invertMediaGestures = false
    // Live activities
    var liveActivitiesEnabled = true
    var inactivityTimeout = 10.0
    var interactiveActivities = true
    var unhideAutomatically = true
    var hideActivitiesOnPlainScreens = false
    var hiddenInFullscreen: [ActivityKind] = []
    var enableGlance = true
    var peekOnSongChange = false
    var activities = Slot<ActivityKind>.all
    // Calendar live activity
    var calendarMinutesBefore = 15.0
    var calendarShowDuringEvent = true
    var calendarShowElapsed = false
    var calendarOnlyMeetings = false
    // Battery live activity
    var batteryShowPlugged = true
    var batteryShowUnplugged = true
    var batteryShowFull = true
    var batteryShowLow = true
    var batteryLowThreshold = 20.0
    // Timer widget
    var timerShowSeconds = true
    var timerPlaySound = true
    // Media live activity
    var mediaEffect = MediaEffect.spectrograph
    var coloredEffects = true
    var albumCornerRadius = 6.0
    var gifScale = 1.0
    var gifOffsetX = 0.0
    var gifOffsetY = 0.0
    var gifPixelPerfect = false
    // Nook
    var openNotchSize = OpenNotchSize.compact
    var nookEnabled = true
    var showDividers = true
    var widgets = Slot<WidgetKind>.all
    // Tray
    var trayFolder: String?  // nil = default
    var trayMoveOnDrop = false
    var trayAutoClearDays = 0.0

    func isEnabled(_ kind: ActivityKind) -> Bool { activities.contains { $0.kind == kind && $0.enabled } }

    /// Fields that change window geometry and require rebuilding the notch windows.
    var layoutKey: [Double] {
        [notchWidthFineTune, notchHeightFineTune, enableOnNonNotchScreens ? 1 : 0, handleWidth, handleHeight]
    }
}

extension Notification.Name {
    static let notchLayoutChanged = Notification.Name("notchd.layoutChanged")
}

@Observable
final class Settings {
    static let shared = Settings()
    private static let key = "prefs"
    private let defaults: UserDefaults

    var prefs: Prefs {
        didSet {
            guard prefs != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(prefs), forKey: Self.key)
            if prefs.layoutKey != oldValue.layoutKey {
                NotificationCenter.default.post(name: .notchLayoutChanged, object: nil)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefs = Self.load(from: defaults)
    }

    /// Stored values are merged over the defaults so newly added fields don't wipe existing prefs.
    private static func load(from defaults: UserDefaults) -> Prefs {
        guard let stored = defaults.data(forKey: key),
              let storedDict = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Prefs())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(storedDict) { $1 }),
              var prefs = try? JSONDecoder().decode(Prefs.self, from: merged) else { return Prefs() }
        prefs.activities = Slot.normalized(prefs.activities)
        prefs.widgets = Slot.normalized(prefs.widgets)
        return prefs
    }

    func reset() {
        var reset = Prefs()
        reset.didShowWelcome = prefs.didShowWelcome
        // Storage is data, not appearance: only Tray's folder controls should move it.
        reset.trayFolder = prefs.trayFolder
        prefs = reset
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("[Settings] launch at login: \(error)")
            }
        }
    }
}

// MARK: - Window

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let panes: [(String, String, AnyView)] = [
                ("General", "gearshape.fill", AnyView(GeneralPane())),
                ("Gestures", "hand.tap.fill", AnyView(GesturesPane())),
                ("Live Activities", "clock.badge.fill", AnyView(LiveActivitiesPane())),
                ("Widgets", "rectangle.topthird.inset.filled", AnyView(NookPane())),
                ("Tray", "tray.fill", AnyView(TrayPane())),
                ("About", "ellipsis.circle.fill", AnyView(AboutPane())),
            ]
            for (title, icon, view) in panes {
                let host = NSHostingController(rootView: view.fixedSize())
                host.sizingOptions = .preferredContentSize
                host.title = title  // becomes the window title
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            // Dev: `--args -debugSettingsTab 2 -debugSubTab 1` opens a given pane (launch args land in UserDefaults).
            tabs.selectedTabViewItemIndex = UserDefaults.standard.integer(forKey: "debugSettingsTab")
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Panes

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Pane<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Form { content }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(width: 520)
    }
}

private struct GeneralPane: View {
    @Bindable private var settings = Settings.shared
    @Local private var launchAtLogin = Settings.shared.launchAtLogin

    var body: some View {
        Pane {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, value in settings.launchAtLogin = value }
            Divider().padding(.vertical, 6)

            Picker("Over fullscreen apps:", selection: $settings.prefs.showInFullscreen) {
                ForEach(FullscreenMode.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            LabeledContent("Notch:") {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Pill-shaped buttons", isOn: $settings.prefs.preferRoundButtons)
                        Caption("Turn off for rounded squares.")
                    }
                    Toggle("Frosted glass background (experimental)", isOn: $settings.prefs.translucentBackground)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Open as soon as the pointer reaches it", isOn: $settings.prefs.alwaysOpenOnHover)
                        Caption("No click or swipe needed.")
                    }
                    Toggle("Haptic feedback", isOn: Binding(get: { !settings.prefs.disableHaptics },
                                                           set: { settings.prefs.disableHaptics = !$0 }))
                }
            }
            LabeledContent("While typing:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Stay open when the pointer leaves", isOn: $settings.prefs.preventCloseWhenTyping)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Pin it open", isOn: $settings.prefs.lockWhileTyping)
                        Caption("Typing turns the lock on; click the lock to release it.")
                    }
                }
            }
            LabeledContent("Inner spacing:") {
                ValueSlider(value: $settings.prefs.contentPadding, range: 4...24)
            }
            LabeledContent("Notch size:") {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Measured automatically. Nudge it if the edges don't line up with your camera housing.")
                    ValueSlider(title: "Width:", value: $settings.prefs.notchWidthFineTune, range: -20...20)
                    ValueSlider(title: "Height:", value: $settings.prefs.notchHeightFineTune, range: -20...20)
                }
            }
            Divider().padding(.vertical, 6)

            LabeledContent("Screens without a notch:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show a handle", isOn: $settings.prefs.enableOnNonNotchScreens)
                    Group {
                        ValueSlider(title: "Width:", value: $settings.prefs.handleWidth, range: 100...300)
                        ValueSlider(title: "Height:", value: $settings.prefs.handleHeight, range: 4...20)
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Invisible until hovered", isOn: $settings.prefs.transparentHandle)
                        }
                    }
                    .disabled(!settings.prefs.enableOnNonNotchScreens)
                }
            }
            Divider().padding(.vertical, 6)

            LabeledContent("More:") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Presentation mode", isOn: $settings.prefs.demoMode)
                        Caption("Keeps everything on screen: nothing closes or times out. Handy when recording a demo.")
                    }
                    Button("Show the welcome tour") { WelcomeWindowController.shared.show() }
                    Button("Reset all settings") { settings.reset() }
                    Caption("Your tray folder and files stay where they are.")
                    Button("Quit Notchd") { NSApp.terminate(nil) }
                    Caption("Tip: right-click the notch for Settings and Quit.")
                }
            }
        }
    }
}

/// Continuous slider (no tick marks) that snaps to whole numbers.
private struct ValueSlider: View {
    var title: String?
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            if let title { Text(title).frame(width: 50, alignment: .leading) }
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
            Text("\(Int(value))").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }
}

private struct GesturesPane: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Pane {
            Toggle("Trackpad gestures on the notch", isOn: $settings.prefs.allowGestures)
            Group {
                Toggle("Swipe down to open, up to close", isOn: $settings.prefs.gestureOpenClose)
                Toggle("Swipe sideways to skip tracks", isOn: $settings.prefs.gestureControlMedia)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Reverse skip direction", isOn: $settings.prefs.invertMediaGestures)
                        .disabled(!settings.prefs.gestureControlMedia)
                    Caption("Off: swipe right for the next track. On: swipe left for the next track.")
                }
            }
            .disabled(!settings.prefs.allowGestures)
            .padding(.leading, 20)
        }
    }
}

private struct LiveActivitiesPane: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        SubTabs(customizeTitle: "Activities") {
            Pane {
                Toggle("Show live activities", isOn: $settings.prefs.liveActivitiesEnabled)
                Divider().padding(.vertical, 6)
                LabeledContent("Hide after:") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Slider(value: $settings.prefs.inactivityTimeout, in: 1...30, step: 1)
                            Text("\(Int(settings.prefs.inactivityTimeout))s").monospacedDigit().frame(width: 32)
                        }
                        Caption("How long an activity lingers once it goes idle, e.g. after you pause the music.")
                    }
                }
                LabeledContent("Behavior:") {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Clickable buttons", isOn: $settings.prefs.interactiveActivities)
                            Caption("Join a call or stop a timer right from the notch. When off, a click just opens it.")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Bring hidden activities back", isOn: $settings.prefs.unhideAutomatically)
                            Caption("Swipe up to tuck an activity away. With this on, it returns on its own when there's news (a new song, a new file). Otherwise, swipe down to restore it.")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Only on screens with a notch", isOn: $settings.prefs.hideActivitiesOnPlainScreens)
                        }
                    }
                }
                LabeledContent("Glance:") {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Glance on hover", isOn: $settings.prefs.enableGlance)
                            Caption("Point at an activity and a line of details slides out below it.")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Glance at new songs", isOn: $settings.prefs.peekOnSongChange)
                            Caption("Shows the title for a few seconds whenever the track changes.")
                        }
                        .disabled(!settings.prefs.enableGlance)
                    }
                }
                LabeledContent("Over fullscreen apps:") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ActivityKind.allCases) { kind in
                            Toggle(isOn: fullscreenBinding(kind)) {
                                Label(kind.title, systemImage: kind.icon)
                            }
                        }
                        Caption("Activities that may appear while you watch or work in fullscreen.")
                    }
                }
                .disabled(!settings.prefs.liveActivitiesEnabled)
            }
        } customize: {
            CustomizeActivities()
        }
    }
}

private extension LiveActivitiesPane {
    func fullscreenBinding(_ kind: ActivityKind) -> Binding<Bool> {
        Binding(
            get: { !settings.prefs.hiddenInFullscreen.contains(kind) },
            set: { visible in
                settings.prefs.hiddenInFullscreen.removeAll { $0 == kind }
                if !visible { settings.prefs.hiddenInFullscreen.append(kind) }
            }
        )
    }
}

private struct CustomizeActivities: View {
    @Bindable private var settings = Settings.shared
    @Local private var selection: ActivityKind? = Settings.shared.prefs.activities.first?.kind

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            SlotList(slots: $settings.prefs.activities, selection: $selection,
                     caption: "Drag to set priority: when several are active, the top one wins.")
            let shown = selection ?? settings.prefs.activities.first?.kind ?? .media
            VStack(spacing: 20) {
                ActivityPreview(kind: shown)
                switch shown {
                case .media: MediaActivityOptions()
                case .calendar: CalendarActivityOptions()
                case .battery: BatteryActivityOptions()
                case .tray, .bluetooth, .timerExpired, .updateAvailable: Caption("Nothing to configure here.")
                }
            }
            .frame(width: 380)
        }
        .padding(24)
    }
}

/// Black mini-notch showing what the selected activity looks like, with the current options.
private struct ActivityPreview: View {
    let kind: ActivityKind
    private var prefs: Prefs { Settings.shared.prefs }

    init(kind: ActivityKind) { self.kind = kind }

    var body: some View {
        let info = MediaManager.shared.nowPlaying ?? .sample
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black)
            HStack(spacing: 0) {
                Group {
                    switch kind {
                    case .media: MediaActivityLeading(info: info, cornerRadius: prefs.albumCornerRadius)
                    case .tray: Image(systemName: "tray.fill").foregroundStyle(.white)
                    case .calendar: CalendarActivityLeading(event: .sample)
                    case .bluetooth: BluetoothActivityLeading(event: .sample)
                    case .timerExpired: TimerActivityLeading()
                    case .updateAvailable: UpdateActivityLeading()
                    case .battery: BatteryActivityLeading(percent: 82, state: .plugged)
                    }
                }
                .frame(width: NotchModel.activitySide)
                Spacer(minLength: 140)
                Group {
                    switch kind {
                    case .media: MediaEffectView(info: info, effect: prefs.mediaEffect, colored: prefs.coloredEffects)
                    case .tray: Text("3").font(.system(size: 13, weight: .semibold, design: .rounded))
                    case .calendar: CalendarActivityTrailing(event: .sample)
                    case .bluetooth: BluetoothActivityTrailing(event: .sample)
                    case .timerExpired: TimerActivityTrailing()
                    case .updateAvailable: UpdateActivityTrailing()
                    case .battery: BatteryActivityTrailing(percent: 82, state: .plugged)
                    }
                }
                .frame(width: NotchModel.activitySide)
            }
            .frame(width: 140 + 2 * NotchModel.activitySide, height: 32)
            .padding(.top, 6)
        }
        .frame(height: 110)
        .environment(\.colorScheme, .dark)
    }
}

private struct MediaActivityOptions: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            LabeledContent("Artwork roundness:") {
                HStack {
                    Slider(value: $settings.prefs.albumCornerRadius, in: 0...20, step: 1)
                    Text("\(Int(settings.prefs.albumCornerRadius))").monospacedDigit().frame(width: 24)
                }
            }
            Picker("Animation:", selection: $settings.prefs.mediaEffect) {
                ForEach(MediaEffect.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if settings.prefs.mediaEffect == .gif {
                GIFOptions()
            } else {
                LabeledContent("Match artwork color:") {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("", isOn: $settings.prefs.coloredEffects).labelsHidden()
                        Caption("Tints the animation with the cover's main color instead of white.")
                    }
                }
            }
        }
    }
}

private struct CalendarActivityOptions: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            LabeledContent("Minutes ahead:") {
                HStack {
                    Slider(value: $settings.prefs.calendarMinutesBefore, in: 1...60, step: 1)
                    Text("\(Int(settings.prefs.calendarMinutesBefore))").monospacedDigit().frame(width: 24)
                }
            }
            Toggle("Keep showing during the event", isOn: $settings.prefs.calendarShowDuringEvent)
            Toggle("Count up instead of down during it", isOn: $settings.prefs.calendarShowElapsed)
                .disabled(!settings.prefs.calendarShowDuringEvent)
            Toggle("Video calls only", isOn: $settings.prefs.calendarOnlyMeetings)
            Caption("Events with a Google Meet, Zoom, Teams or Webex link get a green button to join in one click.")
        }
        .onChange(of: settings.prefs) { CalendarStore.shared.refreshUpcoming() }
    }
}

private struct BatteryActivityOptions: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Toggle("Charger connected", isOn: $settings.prefs.batteryShowPlugged)
            Toggle("Charger disconnected", isOn: $settings.prefs.batteryShowUnplugged)
            Toggle("Fully charged", isOn: $settings.prefs.batteryShowFull)
            Toggle("Running low", isOn: $settings.prefs.batteryShowLow)
            LabeledContent("Low means under:") {
                HStack {
                    Slider(value: $settings.prefs.batteryLowThreshold, in: 5...50, step: 5)
                    Text("\(Int(settings.prefs.batteryLowThreshold))%").monospacedDigit().frame(width: 36)
                }
            }
            .disabled(!settings.prefs.batteryShowLow)
        }
    }
}

private struct GIFOptions: View {
    @Bindable private var settings = Settings.shared
    private var gif = GIFStore.shared
    private var hasGIF: Bool { gif.url != nil }

    var body: some View {
        LabeledContent("GIF:") {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Button(hasGIF ? "Change…" : "Choose…", action: choose)
                    if hasGIF { Button("Remove") { gif.remove() } }
                }
                if !hasGIF { Caption("Pick any animated GIF. Until you do, the equalizer is shown.") }
            }
        }
        slider("Scale:", $settings.prefs.gifScale, 0.5...2, step: 0.1) { String(format: "%.1f×", $0) }
        slider("Horizontal offset:", $settings.prefs.gifOffsetX, -10...10, step: 1) { "\(Int($0))" }
        slider("Vertical offset:", $settings.prefs.gifOffsetY, -10...10, step: 1) { "\(Int($0))" }
        Picker("Rendering:", selection: $settings.prefs.gifPixelPerfect) {
            Text("Smooth").tag(false)
            Text("Crisp pixels (for pixel art)").tag(true)
        }
        .pickerStyle(.radioGroup)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(format(value.wrappedValue)).monospacedDigit().frame(width: 36)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]
        if panel.runModal() == .OK, let url = panel.url { gif.install(from: url) }
    }
}

private struct NookPane: View {
    @Bindable private var settings = Settings.shared
    /// Settings preview the built-in (notched) screen, where space is tightest.
    static var referenceMaxUnits: Int {
        let screen = NSScreen.screens.first { $0.notchSize != nil } ?? NSScreen.main
        return Grid(prefs: Settings.shared.prefs).maxUnits(screenWidth: screen?.frame.width ?? 1440)
    }
    var body: some View {
        SubTabs(customizeTitle: "Layout") {
            Pane {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Open widgets on click", isOn: $settings.prefs.nookEnabled)
                    Caption("When off, the notch only shows live activities.")
                }
                Divider().padding(.vertical, 6)
                LabeledContent("Open notch size:") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Open notch size", selection: $settings.prefs.openNotchSize) {
                            ForEach(OpenNotchSize.allCases) { size in
                                Text(size.title).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Caption("Compact fits the controls closely. Roomy adds space for longer lists.")
                    }
                }
                Toggle("Separators between widgets", isOn: $settings.prefs.showDividers)
            }
        } customize: {
            WidgetLayoutEditor(settings: settings, maxUnits: Self.referenceMaxUnits)
        }
    }
}

private struct TrayPane: View {
    @Bindable private var settings = Settings.shared
    @Bindable private var tray = TrayStore.shared

    var body: some View {
        Pane {
            LabeledContent("Storage folder:") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tray.folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack {
                        Button("Choose…", action: chooseFolder)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tray.folder]) }
                        Button("Reset to default") { tray.setFolder(nil) }
                            .disabled(settings.prefs.trayFolder == nil)
                    }
                    Caption("Files already in the tray move to the new folder.")
                }
            }
            Divider().padding(.vertical, 6)

            Picker("When dropping files:", selection: $settings.prefs.trayMoveOnDrop) {
                Text("Copy them (keep originals)").tag(false)
                Text("Move them").tag(true)
            }
            .pickerStyle(.radioGroup)
            Caption("Pasting files always makes a copy and keeps the originals.")
            LabeledContent("Auto-clear:") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Slider(value: $settings.prefs.trayAutoClearDays, in: 0...30, step: 1)
                        Text(settings.prefs.trayAutoClearDays == 0 ? "Never" : "\(Int(settings.prefs.trayAutoClearDays))d")
                            .monospacedDigit().frame(width: 44)
                    }
                    Caption("Files older than this go to the Trash. Set to 0 to keep them forever.")
                }
            }
            .onChange(of: settings.prefs.trayAutoClearDays) { tray.reload() }
            Divider().padding(.vertical, 6)

            LabeledContent("More:") {
                VStack(alignment: .leading, spacing: 2) {
                    Button("Clear tray (\(tray.files.count))") { tray.clear() }
                        .disabled(tray.files.isEmpty)
                    Caption("Removed files go to the Trash.")
                }
            }
        }
        .alert(item: $tray.folderChangeNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = tray.folder
        if panel.runModal() == .OK, let url = panel.url { tray.setFolder(url) }
    }
}

// MARK: - Shared settings pieces

/// "General | Customize …" segmented control on top of a pane.
private struct SubTabs<General: View, Customize: View>: View {
    let customizeTitle: String
    @ViewBuilder let general: General
    @ViewBuilder let customize: Customize
    @Local private var tab = UserDefaults.standard.integer(forKey: "debugSubTab")

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text(customizeTitle).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)
            if tab == 0 { general } else { customize }
        }
    }
}

/// Reorderable list of activities or widgets, each with an on/off switch.
private struct SlotList<Kind: SlotKind>: View {
    @Binding var slots: [Slot<Kind>]
    @Binding var selection: Kind?
    let caption: String
    var badge: (Slot<Kind>) -> Text? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach($slots, id: \.kind) { $slot in
                    HStack(spacing: 10) {
                        Image(systemName: slot.kind.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.blue.gradient))
                        Text(slot.kind.title).lineLimit(1)
                        Spacer(minLength: 4)
                        badge(slot)?.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Toggle("", isOn: $slot.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    .tag(slot.kind)
                }
                .onMove { slots.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(width: 270, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Caption(caption).frame(width: 270, alignment: .leading)
        }
    }
}

/// "7 of 12 U used" bar, so you see how much room is left in the notch.
struct UnitsGauge: View {
    let layout: NookLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<max(layout.maxUnits, 1), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i < layout.usedUnits ? Color.accentColor : .secondary.opacity(0.25))
                        .frame(height: 10)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: layout.usedUnits)
            Text("\(layout.usedUnits) of \(layout.maxUnits) U used on this screen")
                .font(.callout.monospacedDigit())
            Caption("1U = \(Int(Grid(prefs: Settings.shared.prefs).unit)) pt. The notch stops growing at 75% of the screen width; widgets past that stay hidden.")
        }
    }
}

private struct AboutPane: View {
    @Bindable private var settings = Settings.shared
    private var updater = Updater.shared
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("notchd").font(.title.bold())
            Text("Version \(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "0"))")
                .foregroundStyle(.secondary)
            Caption("A clean, open-source Dynamic Island–style notch for your Mac.")

            Divider().padding(.vertical, 6)

            HStack {
                Button("Check for Updates") { updater.check() }
                    .disabled(updater.status == .checking || updater.status == .installing)
                Toggle("Check automatically", isOn: $settings.prefs.autoCheckUpdates)
            }
            Group {
                switch updater.status {
                case .idle: Text(" ")
                case .checking: Text("Checking…")
                case .upToDate: Text("You're up to date.")
                case let .available(update):
                    HStack {
                        Text("notchd \(update.version) is available.")
                        Button("Install & Relaunch") { updater.install() }
                        Link("Release notes", destination: update.pageURL)
                    }
                case .installing: Text("Downloading and installing…")
                case let .failed(message): Text(message).foregroundStyle(.orange)
                }
            }
            .font(.callout)

            Link("github.com/\(Updater.repo)", destination: URL(string: "https://github.com/\(Updater.repo)")!)
                .font(.callout)
                .padding(.top, 6)
        }
        .padding(30)
        .frame(width: 520)
    }
}
