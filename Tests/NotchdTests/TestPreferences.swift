import Foundation
@testable import Notchd

/// Each test gets its own preferences domain, never the running app's settings.
final class TestPreferences {
    private let name = "notchd-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: Settings

    init() {
        defaults = UserDefaults(suiteName: name)!
        settings = Settings(defaults: defaults)
    }

    deinit { defaults.removePersistentDomain(forName: name) }
}
