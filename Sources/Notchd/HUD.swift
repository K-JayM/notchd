import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

// MARK: - System volume

/// Output volume of the default device, pushed by CoreAudio (no polling, no permission).
@Observable
final class AudioVolume {
    static let shared = AudioVolume()

    /// 0...1, nil when the device has no software volume (some HDMI/USB outputs).
    private(set) var level: Double?
    private(set) var muted = false
    /// Effective loudness for visuals: 0 when muted.
    var loudness: Double { muted ? 0 : level ?? 1 }

    /// Called on user-visible changes (not on device switches).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var deviceSwitchedAt = Date.distantPast
    @ObservationIgnored private let queue = DispatchQueue.main

    @ObservationIgnored private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.rebind()
    }
    @ObservationIgnored private lazy var valueListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.read(notify: true)
    }

    init() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        rebind()
    }

    private func rebind() {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, valueListener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        device = id
        deviceSwitchedAt = Date()
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(device, &address, queue, valueListener)
        }
        read(notify: false)
    }

    private func read(notify: Bool) {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let newLevel = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? Double(volume) : nil
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyMute)
        let newMuted = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr && mute != 0
        guard newLevel != level || newMuted != muted else { return }
        level = newLevel
        muted = newMuted
        // A new device reports its own volume: that's not the user pressing a key.
        if notify, Date().timeIntervalSince(deviceSwitchedAt) > 1 { onChange?() }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

// MARK: - Display brightness

/// Built-in display brightness through the private DisplayServices framework, loaded at runtime.
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let get: Get? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: Get.self)
    }()

    /// 0...1, nil when there's no built-in display (or the API went away).
    static func current() -> Double? {
        guard let get, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? Double(value) : nil
    }

    private static var builtInDisplay: CGDirectDisplayID? {
        NSScreen.screens.map(\.displayID).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

// MARK: - HUD

struct HUDState: Equatable {
    enum Kind { case volume, brightness }
    var kind: Kind
    var level: Double
    var muted = false
}

/// Replaces the system volume/brightness overlay with one that grows out of the notch.
/// Volume changes come from CoreAudio; brightness is sampled (there's no public change notification).
/// The system overlay (OSDUIHelper) is paused with SIGSTOP while this is on and resumed when it's off.
@Observable
final class HUDCenter {
    static let shared = HUDCenter()
    private(set) var state: HUDState?

    private var hideWork: DispatchWorkItem?
    private var brightnessTimer: Timer?
    private var lastBrightness: Double?
    private var suppressTimer: Timer?

    func start() {
        AudioVolume.shared.onChange = { [weak self] in self?.volumeChanged() }
        // A crash while it was on would leave the system overlay paused for good: resume it at launch.
        if !Settings.shared.prefs.hudEnabled { Self.systemOverlay(paused: false) }
        apply()
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.apply() }
    }

    private var enabled = false

    /// Follows the setting: starts or stops sampling and the system overlay.
    private func apply() {
        let on = Settings.shared.prefs.hudEnabled
        if on {
            Self.systemOverlay(paused: true)
            if brightnessTimer == nil {
                lastBrightness = Brightness.current()
                // ponytail: 5 Hz sampling; swap for a key event tap if it ever costs anything measurable.
                brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    self?.sampleBrightness()
                }
            }
            // macOS relaunches the overlay helper now and then: pause it again.
            if suppressTimer == nil {
                suppressTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                    Self.systemOverlay(paused: true)
                }
            }
        } else if enabled {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
            suppressTimer?.invalidate()
            suppressTimer = nil
            Self.systemOverlay(paused: false)
        }
        enabled = on
    }

    func stop() {
        if enabled { Self.systemOverlay(paused: false) }
    }

    private func volumeChanged() {
        guard enabled, let level = AudioVolume.shared.level else { return }
        show(HUDState(kind: .volume, level: level, muted: AudioVolume.shared.muted))
    }

    private func sampleBrightness() {
        guard let value = Brightness.current() else { return }
        defer { lastBrightness = value }
        guard let last = lastBrightness else { return }
        // Keys move brightness in big steps; auto-brightness drifts slowly. Only show the former.
        if abs(value - last) >= 0.02 || (state?.kind == .brightness && abs(value - last) > 0.001) {
            show(HUDState(kind: .brightness, level: value))
        }
    }

    func show(_ new: HUDState) {
        withAnimation(state == nil ? .notchOpen : .spring(response: 0.25, dampingFraction: 0.8)) { state = new }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(.notchClose) { self?.state = nil } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Pauses (SIGSTOP) or resumes the process that draws the system overlay.
    private static func systemOverlay(paused: Bool) {
        if paused {
            // It only runs once it has shown something: start it so there is a process to pause.
            run("/bin/launchctl", ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"])
            run("/usr/bin/killall", ["-STOP", "OSDUIHelper"])
        } else {
            run("/usr/bin/killall", ["-CONT", "OSDUIHelper"])
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

extension Notification.Name {
    static let prefsChanged = Notification.Name("notchd.prefsChanged")
}

// MARK: - Views

struct HUDLeading: View {
    let state: HUDState

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 22)
    }

    private var icon: String {
        switch state.kind {
        case .brightness: state.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if state.muted || state.level == 0 { "speaker.slash.fill" }
            else if state.level < 0.33 { "speaker.wave.1.fill" }
            else if state.level < 0.66 { "speaker.wave.2.fill" }
            else { "speaker.wave.3.fill" }
        }
    }
}

struct HUDTrailing: View {
    let state: HUDState

    var body: some View {
        Text("\(Int((state.muted ? 0 : state.level) * 100))")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: state.level))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.level)
    }
}

/// The level bar under the HUD row, in 16 steps like the keyboard keys.
struct HUDBar: View {
    let state: HUDState

    var body: some View {
        let level = state.muted ? 0 : state.level
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(color(level))
                    .frame(width: max(6, geo.size.width * level))
                    .opacity(level > 0 ? 1 : 0)
            }
        }
        .frame(height: 6)
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: level)
    }

    private func color(_ level: Double) -> Color {
        if state.kind == .brightness { return .yellow }
        guard Settings.shared.prefs.hudColoredVolume else { return .white }
        return level > 0.9 ? .red : level > 0.7 ? .orange : .white
    }
}
