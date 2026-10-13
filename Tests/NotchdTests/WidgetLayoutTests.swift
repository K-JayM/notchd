import Foundation
@testable import Notchd
import Testing

@Test func modulePlacementPreservesWidthAndOrderAcrossRestart() {
    let preferences = TestPreferences()
    let settings = preferences.settings
    settings.prefs.widgets.firstIndex { $0.kind == .timer }.map { settings.prefs.widgets[$0].units = 4 }
    #expect(settings.placeWidget(.timer, before: .calendar, maxUnits: 20))
    #expect(settings.prefs.widgets.map(\.kind) == [.media, .timer, .calendar, .todo, .capture])
    #expect(settings.prefs.widgets[1].units == 4)
    #expect(settings.prefs.widgets[1].enabled)
    #expect(settings.placeWidget(.timer, maxUnits: 20))
    #expect(settings.prefs.widgets.map(\.kind) == [.media, .calendar, .todo, .capture, .timer])
    #expect(settings.placeWidget(.timer, before: .timer, maxUnits: 20))
    #expect(settings.prefs.widgets.count == WidgetKind.allCases.count)
    settings.removeWidget(.timer)
    #expect(settings.prefs.widgets.last?.enabled == false)
    #expect(settings.placeWidget(.timer, before: .media, maxUnits: 20))
    #expect(settings.prefs.widgets.first?.units == 4)
    #expect(Settings(defaults: preferences.defaults).prefs.widgets == settings.prefs.widgets)
}

@Test func modulePlacementRejectsInsufficientRoomWithoutChangingPreferences() {
    let preferences = TestPreferences()
    let settings = preferences.settings
    let before = settings.prefs
    #expect(!settings.placeWidget(.timer, maxUnits: 9))
    #expect(settings.prefs == before)
    // Inserting at the front prioritizes the dropped module when the rest overflow.
    #expect(settings.placeWidget(.timer, before: .media, maxUnits: 9))
    #expect(NookLayout.fit(settings.prefs.widgets, maxUnits: 9).shown.first == .timer)
    let after = settings.prefs
    #expect(!settings.placeWidget(.media, before: .timer, maxUnits: 2))
    #expect(settings.prefs == after)
}

@Test func olderWidgetListsGainCaptureWithoutLosingChoices() throws {
    let preferences = TestPreferences()
    var stored = Prefs()
    stored.widgets = [Slot(kind: .todo, customUnits: 3), Slot(kind: .media, enabled: false),
                      Slot(kind: .timer, customUnits: 4), Slot(kind: .calendar)]
    preferences.defaults.set(try JSONEncoder().encode(stored), forKey: "prefs")
    let loaded = Settings(defaults: preferences.defaults)
    #expect(Array(loaded.prefs.widgets.prefix(4)) == stored.widgets)
    #expect(loaded.prefs.widgets.last == Slot(kind: .capture))
}
