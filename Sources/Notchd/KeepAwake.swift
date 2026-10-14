import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Keeps the Mac (and, by default, the display) awake with a power assertion, like `caffeinate`.
@Observable
final class KeepAwake {
    static let shared = KeepAwake()
    private(set) var isOn = false
    /// nil = until turned off.
    private(set) var endsAt: Date?
    private var assertion = IOPMAssertionID(0)
    private var timer: Timer?

    /// Choices in the menu, in minutes; 0 = until turned off.
    static let durations = [0, 15, 30, 60, 120, 300]

    static func title(minutes: Int) -> String {
        switch minutes {
        case 0: L("Until I turn it off")
        case ..<60: String(localized: "For \(minutes) minutes")
        case 60: L("For 1 hour")
        default: String(localized: "For \(minutes / 60) hours")
        }
    }

    func turnOn(minutes: Int) {
        release()
        let type = Settings.shared.prefs.keepAwakeDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                                          : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Notchd keep awake" as CFString, &assertion)
        guard result == kIOReturnSuccess else {
            NSLog("[KeepAwake] assertion failed: \(result)")
            withAnimation(.notchClose) {
                isOn = false
                endsAt = nil
            }
            return
        }
        withAnimation(.notchOpen) {
            isOn = true
            endsAt = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let endsAt, endsAt <= .now else { return }
            turnOff()
        }
    }

    func turnOff() {
        release()
        withAnimation(.notchClose) {
            isOn = false
            endsAt = nil
        }
    }

    func toggle() { isOn ? turnOff() : turnOn(minutes: 0) }

    /// The setting switched between keeping the display or only the Mac awake: swap the assertion.
    func settingsChanged() {
        guard isOn else { return }
        let minutes = endsAt.map { max(1, Int($0.timeIntervalSinceNow / 60)) } ?? 0
        turnOn(minutes: minutes)
    }

    private func release() {
        timer?.invalidate()
        timer = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

/// Cup in the open notch's header: click for the durations.
struct KeepAwakeButton: View {
    private var keepAwake = KeepAwake.shared

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: keepAwake.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(keepAwake.isOn ? .orange : .secondary)
                .frame(width: 26, height: 22)
                .background(Pill().fill(.white.opacity(keepAwake.isOn ? 0.2 : 0.08)))
        }
        .buttonStyle(BouncyButtonStyle())
        .help(keepAwake.isOn ? Text("Keeping your Mac awake") : Text("Keep your Mac awake"))
    }

    private func showMenu() {
        Haptics.tap()
        let menu = ClosureMenu()
        if keepAwake.isOn {
            menu.add(L("Turn Off")) { KeepAwake.shared.turnOff() }
            menu.addItem(.separator())
        }
        for minutes in KeepAwake.durations {
            menu.add(KeepAwake.title(minutes: minutes)) { KeepAwake.shared.turnOn(minutes: minutes) }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Live activity

struct KeepAwakeActivityLeading: View {
    var body: some View {
        Image(systemName: "cup.and.heat.waves.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.orange)
            .symbolEffect(.pulse)
    }
}

/// Time left, or ∞; click to stop.
struct KeepAwakeActivityTrailing: View {
    private var keepAwake = KeepAwake.shared

    var body: some View {
        Button {
            keepAwake.turnOff()
            Haptics.tap()
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Group {
                    if let endsAt = keepAwake.endsAt {
                        Text(CalendarActivityTrailing.format(max(0, endsAt.timeIntervalSince(timeline.date))))
                    } else {
                        Image(systemName: "infinity")
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.orange)
            }
        }
        .buttonStyle(BouncyButtonStyle())
        .help(Text("Stop keeping awake"))
    }
}
