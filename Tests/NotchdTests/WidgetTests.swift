import AppKit
@testable import Notchd
import Testing

@Test func todoStarsAndCleanup() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchd-todo-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = TodoStore(file: file)
    store.items = [TodoItem(title: "new"), TodoItem(title: "starred"), TodoItem(title: "done")]
    store.items[1].starred = true
    store.items[2].done = true
    #expect(store.items[2].doneAt != nil)

    // Starred first, the rest keeps its order; completed ones can be hidden.
    #expect(store.visible(showCompleted: true).map(\.title) == ["starred", "new", "done"])
    #expect(store.visible(showCompleted: false).map(\.title) == ["starred", "new"])

    // Completed tasks go away N days after being checked off (7 by default), unchecked ones never.
    store.clearOld(now: .now.addingTimeInterval(6 * 86_400))
    #expect(store.items.count == 3)
    store.clearOld(now: .now.addingTimeInterval(8 * 86_400))
    #expect(store.items.map(\.title) == ["new", "starred"])

    // Saved and read back, including files from before stars existed.
    #expect(TodoStore(file: file).items.map(\.starred) == [false, true])
    try Data(#"[{"id":"\#(UUID().uuidString)","title":"old","done":false}]"#.utf8).write(to: file)
    #expect(TodoStore(file: file).items.first?.title == "old")
}

@Test func notesCodeToggle() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchd-notes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = NotesStore(file: file)
    let id = try #require(store.selected?.id)
    store.update(id) { $0.rtf = NotesStore.rtf(NSAttributedString(string: "Shopping\nmilk")) }
    #expect(store.selected?.title == "Shopping")

    // Rich → code keeps the words; and back.
    store.toggleCode(id)
    #expect(store.selected?.code == true)
    #expect(store.selected?.text == "Shopping\nmilk")
    store.toggleCode(id)
    #expect(store.selected?.title == "Shopping")

    // A new note reuses an empty one rather than piling them up.
    store.add()
    store.add()
    #expect(store.notes.count == 2)
    store.save()
    #expect(NotesStore(file: file).notes.count == 2)
}

@Test func timerLabels() {
    let entry = TimerEntry(seconds: 60, label: "Tea")
    #expect(entry.label == "Tea")
}

@Test @MainActor func noteStyling() {
    let text = NoteTextView()
    text.textStorage?.setAttributedString(NSAttributedString(string: "Hello world", attributes: NoteTextView.richAttributes))
    text.setSelectedRange(NSRange(location: 0, length: 5))
    text.toggleBold(nil)
    let bold = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    let rest = text.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
    #expect(rest.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == false)
    text.toggleBold(nil)  // toggles back
    let plain = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(plain.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == false)
}
