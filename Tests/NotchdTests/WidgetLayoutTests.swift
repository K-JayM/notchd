import AppKit
@testable import Notchd
import Testing

@Test func modulePlacementPreservesWidthAndOrderAcrossRestart() {
    let preferences = TestPreferences()
    let settings = preferences.settings
    settings.prefs.widgets.firstIndex { $0.kind == .timer }.map { settings.prefs.widgets[$0].units = 4 }
    #expect(settings.placeWidget(.timer, before: .calendar, maxUnits: 20))
    #expect(settings.prefs.widgets.map(\.kind) == [.media, .timer, .calendar, .todo, .notes, .shortcuts, .mirror, .capture,
                                                   .pomodoro, .stats, .weather, .colors])
    #expect(settings.prefs.widgets[1].units == 4)
    #expect(settings.prefs.widgets[1].enabled)
    #expect(settings.placeWidget(.timer, maxUnits: 20))
    #expect(settings.prefs.widgets.map(\.kind) == [.media, .calendar, .todo, .notes, .shortcuts, .mirror, .capture,
                                                   .pomodoro, .stats, .weather, .colors, .timer])
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
    #expect(loaded.prefs.widgets.first { $0.kind == .capture } == Slot(kind: .capture))
    // Modules added later arrive switched off, so an update never changes someone's notch.
    #expect(loaded.prefs.widgets.suffix(4).map(\.kind) == [.pomodoro, .stats, .weather, .colors])
    #expect(loaded.prefs.widgets.suffix(4).allSatisfy { !$0.enabled })
    #expect(loaded.prefs.widgets.filter(\.enabled).map(\.kind) == [.todo, .timer, .calendar, .capture])
}

@Test(arguments: [WidgetKind.notes, .shortcuts, .mirror, .pomodoro, .stats, .weather, .colors])
func newModulesCanBePlacedWithoutEnablingOtherOptionalModules(kind: WidgetKind) {
    let preferences = TestPreferences()
    let settings = preferences.settings
    #expect(settings.prefs.widgets.filter(\.enabled).map(\.kind) == [.media, .calendar, .todo, .capture])
    #expect(settings.placeWidget(kind, before: .media, maxUnits: 20))
    #expect(NookLayout.fit(settings.prefs.widgets, maxUnits: 20).shown.first == kind)
    #expect(Settings(defaults: preferences.defaults).prefs.widgets == settings.prefs.widgets)
    settings.removeWidget(kind)
    #expect(settings.prefs.widgets.filter(\.enabled).map(\.kind) == [.media, .calendar, .todo, .capture])
}

@Test @MainActor func modulePayloadsAreIgnoredByFileDropLoading() async {
    let module = WidgetDrag.provider(for: .notes)
    let text = NSItemProvider(object: "ordinary tray text" as NSString)
    let items: [DroppedItem] = await withCheckedContinuation { continuation in
        DroppedItem.load([module, text]) { continuation.resume(returning: $0) }
    }
    #expect(items.count == 1)
    guard case let .text(value) = items.first else {
        Issue.record("Only the ordinary text drag should reach the tray"); return
    }
    #expect(value == "ordinary tray text")
}
