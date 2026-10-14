import SwiftUI

struct FocusEvent: Equatable {
    var name: String
    var symbol: String
    var color: Color
    var on: Bool

    static let sample = FocusEvent(name: "Do Not Disturb", symbol: "moon.fill", color: .indigo, on: true)
}

/// Focus changes, read from the Do Not Disturb database macOS keeps in ~/Library/DoNotDisturb.
/// There's no public API for this; reading those files needs Full Disk Access, which Settings explains.
@Observable
final class FocusMonitor {
    static let shared = FocusMonitor()
    /// The Focus that's on, nil when none is.
    private(set) var current: FocusEvent?
    /// The database couldn't be read: Notchd doesn't have Full Disk Access.
    private(set) var needsAccess = false
    private var timer: Timer?
    private var started = false

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)

    func apply() {
        let prefs = Settings.shared.prefs
        let wanted = prefs.isEnabled(.focus) && prefs.liveActivitiesEnabled
        if wanted, timer == nil {
            started = false
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    func refresh() {
        guard let assertions = try? Data(contentsOf: Self.folder.appendingPathComponent("Assertions.json")) else {
            needsAccess = true
            return
        }
        needsAccess = false
        let configurations = try? Data(contentsOf: Self.folder.appendingPathComponent("ModeConfigurations.json"))
        let mode = Self.activeMode(assertions)
        let event = mode.map { Self.describe($0, configurations: configurations) }
        defer {
            current = event
            started = true
        }
        // Only changes after launch flash: starting up in a Focus isn't news.
        guard started, event?.name != current?.name || (event == nil) != (current == nil) else { return }
        if let event {
            ActivityCenter.shared.show(.focus(event), for: 3)
        } else if var ended = current {
            ended.on = false
            ActivityCenter.shared.show(.focus(ended), for: 2.5)
        }
    }

    /// The mode identifier of the newest assertion (a Focus turned on by hand or by a shortcut).
    static func activeMode(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: [(id: String, start: Double)] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let details = dict["assertionDetails"] as? [String: Any],
                   let id = details["assertionDetailsModeIdentifier"] as? String {
                    found.append((id, dict["assertionStartDateTimestamp"] as? Double ?? 0))
                }
                dict.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return found.max { $0.start < $1.start }?.id
    }

    /// Name, symbol and color of a mode, as set up in System Settings › Focus.
    static func describe(_ identifier: String, configurations: Data?) -> FocusEvent {
        var name: String?, symbol: String?, tint: String?
        if let data = configurations, let json = try? JSONSerialization.jsonObject(with: data) {
            func walk(_ value: Any) {
                if let dict = value as? [String: Any] {
                    if dict["modeIdentifier"] as? String == identifier {
                        name = dict["name"] as? String ?? name
                        symbol = dict["symbolImageName"] as? String ?? symbol
                        tint = dict["tintColorName"] as? String ?? tint
                    }
                    dict.values.forEach(walk)
                } else if let array = value as? [Any] {
                    array.forEach(walk)
                }
            }
            walk(json)
        }
        let fallbackName = identifier.hasSuffix(".default") ? L("Do Not Disturb")
            : identifier.split(separator: ".").last.map { String($0).capitalized } ?? L("Focus")
        return FocusEvent(name: name ?? fallbackName, symbol: symbol ?? "moon.fill", color: color(tint), on: true)
    }

    static func color(_ name: String?) -> Color {
        switch name?.replacingOccurrences(of: "system", with: "").replacingOccurrences(of: "Color", with: "").lowercased() {
        case "purple": .purple
        case "orange": .orange
        case "green": .green
        case "blue": .blue
        case "teal": .teal
        case "pink": .pink
        case "red": .red
        case "yellow": .yellow
        case "mint": .mint
        case "cyan": .cyan
        case "brown": .brown
        case "gray": .gray
        default: .indigo
        }
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

// MARK: - Live activity

struct FocusActivityLeading: View {
    let event: FocusEvent

    var body: some View {
        Image(systemName: event.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(event.on ? event.color : .secondary)
            .symbolEffect(.bounce, value: event.on)
    }
}

struct FocusActivityTrailing: View {
    let event: FocusEvent

    var body: some View {
        Text(event.on ? "On" : "Off")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(event.on ? event.color : .secondary)
    }
}
