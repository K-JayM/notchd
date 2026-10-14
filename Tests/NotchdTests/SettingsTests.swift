import Foundation
@testable import Notchd
import Testing

@Test(arguments: [false, true])
func settingsResetPreservesTrayAcrossRestart(welcomed: Bool) throws {
    let preferences = TestPreferences()
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("notchd-reset-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let settings = preferences.settings
    settings.prefs.trayFolder = folder.path
    settings.prefs.didShowWelcome = welcomed
    settings.prefs.trayMoveOnDrop = true
    settings.prefs.alwaysOpenOnHover = true
    settings.prefs.mediaEffect = .waves
    let tray = TrayStore(settings: settings)
    tray.add(text: "keep my tray contents")

    settings.reset()

    var expected = Prefs()
    expected.trayFolder = folder.path
    expected.didShowWelcome = welcomed
    #expect(settings.prefs == expected)
    #expect(tray.folder == folder)
    let restartedSettings = Settings(defaults: preferences.defaults)
    #expect(restartedSettings.prefs == expected)
    let restartedTray = TrayStore(settings: restartedSettings)
    #expect(restartedTray.folder == folder)
    #expect(restartedTray.files == tray.files)
    let kept = try #require(restartedTray.files.first)
    #expect(try String(contentsOf: kept, encoding: .utf8) == "keep my tray contents")
}

@Test func settingsResetKeepsDefaultTrayLocation() {
    let preferences = TestPreferences()
    preferences.settings.prefs.trayMoveOnDrop = true
    preferences.settings.reset()
    #expect(preferences.settings.prefs == Prefs())
    #expect(Settings(defaults: preferences.defaults).prefs == Prefs())
}

@Test func existingPreferencesAdoptCompactSizeWithoutLosingCustomization() throws {
    let preferences = TestPreferences()
    var stored = Prefs()
    stored.widgets[0].customUnits = 4
    stored.widgets[1].enabled = false
    stored.contentPadding = 18
    stored.trayFolder = "/tmp/custom-tray"
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
    json.removeValue(forKey: "openNotchSize")
    preferences.defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "prefs")

    let loaded = Settings(defaults: preferences.defaults)
    #expect(loaded.prefs == stored)
    #expect(loaded.prefs.openNotchSize == .compact)
    loaded.prefs.openNotchSize = .roomy
    #expect(Settings(defaults: preferences.defaults).prefs.openNotchSize == .roomy)
}
