import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildWindows()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildWindows() }
        NotificationCenter.default.addObserver(forName: .notchLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildWindows()
        }

        BatteryMonitor.shared.start()
        MediaManager.shared.start()
        BluetoothMonitor.shared.start()
        _ = TimersStore.shared  // rings even if the timer widget is never shown
        _ = FullscreenMonitor.shared

        // Dev: `--args -demo battery|unplugged|full|low|bluetooth|timer|peek` fires a sample activity.
        if let demo = UserDefaults.standard.string(forKey: "demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                switch demo {
                case "bluetooth": ActivityCenter.shared.show(.bluetooth(.sample))
                case "timer": TimersStore.shared.start(seconds: 3)
                case "peek": ActivityCenter.shared.peek(for: 10)
                case "unplugged": ActivityCenter.shared.show(.battery(percent: 64, state: .unplugged))
                case "full": ActivityCenter.shared.show(.battery(percent: 100, state: .full))
                case "low": ActivityCenter.shared.show(.battery(percent: 15, state: .low))
                default: ActivityCenter.shared.show(.battery(percent: 82, state: .plugged))
                }
            }
        }
        if CommandLine.arguments.contains("--settings") { SettingsWindowController.shared.show() }
        if CommandLine.arguments.contains("--welcome") { WelcomeWindowController.shared.show() } else {
            WelcomeWindowController.shared.showIfFirstLaunch()
        }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let model = self?.controllers.first?.model else { return }
                model.locked = true
                if UserDefaults.standard.string(forKey: "debugTab") == "tray" { model.tab = .tray }
                model.open()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaManager.shared.stop()
    }

    private func rebuildWindows() {
        controllers.forEach { $0.close() }
        let showOnPlainScreens = Settings.shared.prefs.enableOnNonNotchScreens
        controllers = NSScreen.screens
            .filter { $0.notchSize != nil || showOnPlainScreens }
            .map(NotchController.init)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
