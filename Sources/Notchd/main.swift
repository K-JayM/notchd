import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherInstances()
        handleTerminationSignal()
        rebuildWindows()
        // No Dock icon, no window: a quick wave says "I'm running".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ActivityCenter.shared.show(.hello, for: 2) }
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
        Updater.shared.start()
        HUDCenter.shared.start()
        installMainMenu()

        // Dev: `--args -demo battery|unplugged|full|low|bluetooth|timer|peek|update|install` fires a sample activity.
        if let demo = UserDefaults.standard.string(forKey: "demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                switch demo {
                case "bluetooth": ActivityCenter.shared.show(.bluetooth(.sample))
                case "timer": TimersStore.shared.start(seconds: 3)
                case "peek": ActivityCenter.shared.peek(for: 10)
                case "update": Updater.shared.check()
                case "install":
                    Updater.shared.check()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Updater.shared.install() }
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

    /// One notch is enough: a freshly launched copy (e.g. a new version) replaces any running one.
    private func quitOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where app.processIdentifier != me {
            app.terminate()
        }
    }

    /// `kill`/`pkill` send SIGTERM, which skips applicationWillTerminate and would orphan the media helper.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
    }

    /// Never shown (no Dock icon), but it's what makes ⌘C/⌘V/⌘Z/⌘B work in text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let items: [(String, [(String, String, String)])] = [
            ("Edit", [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")]),
            ("Format", [("Bold", "toggleBold:", "b"), ("Italic", "toggleItalic:", "i"), ("Underline", "underline:", "u")]),
        ]
        for (title, entries) in items {
            let menu = NSMenu(title: title)
            for (name, action, key) in entries {
                menu.addItem(NSMenuItem(title: name, action: Selector(action), keyEquivalent: key))
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        HUDCenter.shared.stop()
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
