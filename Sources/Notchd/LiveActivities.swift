import AppKit
import SwiftUI

enum LiveActivity: Equatable {
    case media
    case tray(count: Int)
    case calendar
    case bluetooth(BluetoothEvent)
    case timerExpired
    case updateAvailable
    case battery(percent: Int, state: BatteryState)
    case focus(FocusEvent)
    case download(DownloadEvent)
    /// The newest busy session, and how many there are.
    case agent(AgentSession, count: Int)
    case agentDone(AgentSession)
    case privacy(camera: Bool, microphone: Bool)
    case pomodoro
    case keepAwake
    /// Launch greeting; not a user-configurable activity.
    case hello
    /// Volume/brightness overlay; always wins while it's up.
    case hud(HUDState)

    var isHUD: Bool { if case .hud = self { true } else { false } }

    var kind: ActivityKind? {
        switch self {
        case .hello, .hud: nil
        case .media: .media
        case .tray: .tray
        case .calendar: .calendar
        case .bluetooth: .bluetooth
        case .timerExpired: .timerExpired
        case .updateAvailable: .updateAvailable
        case .battery: .battery
        case .focus: .focus
        case .download: .download
        case .agent, .agentDone: .agent
        case .privacy: .privacy
        case .pomodoro: .pomodoro
        case .keepAwake: .keepAwake
        }
    }
}

/// Long-lived activities (media) come from their managers; short events flash for a few seconds.
/// When several are active, the user's order in Settings decides which one shows.
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    private(set) var flash: LiveActivity?
    /// Glance shown without hovering (song change), for a few seconds.
    private(set) var autoPeek = false
    private var hideWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?

    func peek(for seconds: Double = 3) {
        withAnimation(.notchOpen) { autoPeek = true }
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(.notchClose) { self?.autoPeek = false } }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Activities swiped away, with what they were showing at the time (see `signature`).
    private(set) var dismissed: [ActivityKind: String] = [:]

    /// The activity a given notch shows: user order, minus dismissed ones and per-screen rules.
    func current(for model: NotchModel) -> LiveActivity? {
        let prefs = Settings.shared.prefs
        if let hud = HUDCenter.shared.state,
           prefs.hudAllScreens || model.displayID == NSScreen.screens.first?.displayID {
            return .hud(hud)
        }
        if flash == .hello { return .hello }
        guard prefs.liveActivitiesEnabled, model.hasNotch || !prefs.hideActivitiesOnPlainScreens else { return nil }
        let fullscreen = FullscreenMonitor.shared.isFullscreen(model.displayID)
        let trayCount = TrayStore.shared.files.count
        let privacy = PrivacyMonitor.shared
        let agents = AgentMonitor.shared.active
        let active = [flash,
                      MediaManager.shared.showActivity ? .media : nil,
                      trayCount > 0 ? .tray(count: trayCount) : nil,
                      CalendarStore.shared.upcoming != nil ? .calendar : nil,
                      TimersStore.shared.hasExpired ? .timerExpired : nil,
                      Updater.shared.available != nil || Updater.shared.status == .installing ? .updateAvailable : nil,
                      privacy.inUse ? .privacy(camera: privacy.camera, microphone: privacy.microphone) : nil,
                      agents.first.map { .agent($0, count: agents.count) },
                      PomodoroStore.shared.isActive ? .pomodoro : nil,
                      KeepAwake.shared.isOn ? .keepAwake : nil]
            .compactMap { $0 }
        forgetEnded(active)
        for slot in prefs.activities where slot.enabled {
            guard let activity = active.first(where: { $0.kind == slot.kind }), !isDismissed(activity),
                  !(fullscreen && prefs.hiddenInFullscreen.contains(slot.kind)) else { continue }
            return activity
        }
        return nil
    }

    /// Swipe up on an activity: flashes end now, long-lived ones hide (and come back per "Unhide automatically").
    func dismiss(_ activity: LiveActivity) {
        withAnimation(.notchClose) {
            switch activity {
            case .battery, .bluetooth, .hello, .focus, .download, .agentDone:
                hideWork?.cancel()
                flash = nil
            case .timerExpired:
                TimersStore.shared.dismissExpired()
            case .hud:
                break
            case .media, .tray, .calendar, .updateAvailable, .privacy, .agent, .pomodoro, .keepAwake:
                if let kind = activity.kind { dismissed[kind] = Self.signature(of: activity) }
            }
        }
    }

    var hasDismissed: Bool { !dismissed.isEmpty }

    /// A swiped-away activity that has since ended (camera off, keep-awake stopped…) shows again next time.
    private func forgetEnded(_ active: [LiveActivity]) {
        let ended = dismissed.keys.filter { kind in !active.contains { $0.kind == kind } }
        guard !ended.isEmpty else { return }
        // Called while SwiftUI reads the notch: change state after this pass, not during it.
        DispatchQueue.main.async { [weak self] in ended.forEach { self?.dismissed[$0] = nil } }
    }

    func unhideAll() {
        withAnimation(.notchOpen) { dismissed = [:] }
    }

    /// With "Unhide automatically", a dismissed activity returns once it shows something new.
    private func isDismissed(_ activity: LiveActivity) -> Bool {
        guard let kind = activity.kind, let hiddenSignature = dismissed[kind] else { return false }
        return !Settings.shared.prefs.unhideAutomatically || hiddenSignature == Self.signature(of: activity)
    }

    /// What makes an activity "new": another song, another file count, another event.
    static func signature(of activity: LiveActivity) -> String {
        switch activity {
        case .media:
            let info = MediaManager.shared.nowPlaying
            return "\(info?.title ?? "")|\(info?.artist ?? "")"
        case let .tray(count):
            return "\(count)"
        case .calendar:
            let event = CalendarStore.shared.upcoming
            return "\(event?.title ?? "")|\(event?.start.timeIntervalSince1970 ?? 0)"
        case .updateAvailable:
            return Updater.shared.available?.version ?? ""
        case let .privacy(camera, microphone):
            return "\(camera)|\(microphone)"
        case let .agent(session, count):
            return "\(session.id)|\(session.state)|\(count)"
        case .pomodoro:
            let state = PomodoroStore.shared.state
            return "\(state.phase)|\(state.waiting)"
        case .battery, .bluetooth, .timerExpired, .hello, .hud, .focus, .download, .agentDone, .keepAwake:
            return ""
        }
    }

    func show(_ activity: LiveActivity, for seconds: Double = 4) {
        guard Settings.shared.prefs.liveActivitiesEnabled else { return }
        withAnimation(.notchOpen) { flash = activity }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.notchClose) { self?.flash = nil }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - Fullscreen

/// Which displays currently show a fullscreen app.
/// Window sizes can't tell (on a notched screen a fullscreen app sits below the notch, exactly like a
/// zoomed window), so we read each display's current Space type: 4 = fullscreen. Private CoreGraphics
/// call, the same one yabai and boring.notch rely on; if it ever disappears we just report no fullscreen.
@Observable
final class FullscreenMonitor {
    static let shared = FullscreenMonitor()
    private(set) var displays: Set<CGDirectDisplayID> = []

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private let mainConnection: MainConnection?
    private let copySpaces: CopyManagedDisplaySpaces?

    init() {
        let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        mainConnection = dlsym(cg, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
        copySpaces = dlsym(cg, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyManagedDisplaySpaces.self) }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Let the fullscreen animation finish first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
            }
        }
        refresh()
    }

    func isFullscreen(_ display: CGDirectDisplayID) -> Bool { displays.contains(display) }

    func refresh() {
        guard let mainConnection, let copySpaces,
              let spaces = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return }
        var result = Set<CGDirectDisplayID>()
        for display in spaces {
            guard let current = display["Current Space"] as? [String: Any], current["type"] as? Int == 4,
                  let identifier = display["Display Identifier"] as? String else { continue }
            // "Main" when "Displays have separate Spaces" is off: one Space spans every display.
            let screens = identifier == "Main" ? NSScreen.screens
                : NSScreen.screens.filter { $0.displayUUID == identifier }
            screens.forEach { result.insert($0.displayID) }
        }
        if result != displays { withAnimation(.notchOpen) { displays = result } }
    }
}

private extension NSScreen {
    var displayUUID: String? {
        CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    }
}

// MARK: - Glance

/// The one-line summary shown under a live activity when peeking.
struct GlanceLine: View {
    let activity: LiveActivity

    var body: some View {
        HStack(spacing: 5) {
            switch activity {
            case .media:
                if let info = MediaManager.shared.nowPlaying {
                    MediaGlance(info: info)
                }
            case let .tray(count):
                Text(count == 1 ? "1 file in tray" : "\(count) files in tray")
            case .calendar:
                if let event = CalendarStore.shared.upcoming {
                    Text(event.title).fontWeight(.semibold)
                    Text(event.start > .now ? "at \(event.start.formatted(date: .omitted, time: .shortened))"
                                            : "until \(event.end.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            case let .bluetooth(event):
                Text(event.name).fontWeight(.semibold)
                Text(event.connected ? "connected" : "disconnected").foregroundStyle(.secondary)
            case let .battery(_, state):
                Text(Self.batteryText(state))
            case .updateAvailable:
                Text("notchd \(Updater.shared.available?.version ?? "")").fontWeight(.semibold)
                Text("is available").foregroundStyle(.secondary)
            case .hello:
                Text("notchd is running").fontWeight(.semibold)
            case .timerExpired:
                if let label = TimersStore.shared.expiredLabel {
                    Text("“\(label)” ended").fontWeight(.semibold)
                } else {
                    Text("Timer ended").fontWeight(.semibold)
                }
            case let .hud(state):
                HUDBar(state: state).padding(.horizontal, 10)
            case let .focus(event):
                Text(event.name).fontWeight(.semibold)
                Text(event.on ? "on" : "off").foregroundStyle(.secondary)
            case let .download(event):
                Text(event.name).fontWeight(.semibold).truncationMode(.middle)
                Text("downloaded").foregroundStyle(.secondary)
            case let .agent(session, count):
                Text(session.project).fontWeight(.semibold)
                switch session.state {
                case .waiting: Text(session.message ?? L("needs your input")).foregroundStyle(.orange)
                default:
                    Text(count > 1 ? String(localized: "and \(count - 1) more working") : L("working…"))
                        .foregroundStyle(.secondary)
                }
            case let .agentDone(session):
                Text(session.project).fontWeight(.semibold)
                Text("\(session.tool.title) finished").foregroundStyle(.secondary)
            case let .privacy(camera, microphone):
                Text(camera && microphone ? L("Camera and microphone in use")
                     : camera ? L("Camera in use") : L("Microphone in use"))
            case .pomodoro:
                let state = PomodoroStore.shared.state
                Text(state.phase.title).fontWeight(.semibold)
                Text(state.waiting ? L("ready when you are") : String(localized: "session \(state.round + 1)"))
                    .foregroundStyle(.secondary)
            case .keepAwake:
                if let end = KeepAwake.shared.endsAt {
                    Text("Awake until \(end.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Keeping your Mac awake")
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    static func batteryText(_ state: BatteryState) -> String {
        let minutes = BatteryMonitor.minutesRemaining()
        let time = minutes.map { $0 >= 60 ? "\($0 / 60)h \($0 % 60)m" : "\($0)m" }
        switch state {
        case .plugged: return time.map { String(localized: "Charging · \($0) to full") } ?? L("Charging")
        case .unplugged: return time.map { String(localized: "On battery · \($0) left") } ?? L("On battery")
        case .full: return L("Fully charged")
        case .low: return time.map { String(localized: "Low battery · \($0) left") } ?? L("Low battery")
        }
    }
}
