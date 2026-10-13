import AppKit
@testable import Notchd
import Testing

@Test func trayPasteRenameReconcile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchd-tray-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TrayStore(folder: dir)
    let pasteboard = NSPasteboard(name: .init("notchd-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    // Text → .txt
    pasteboard.clearContents()
    pasteboard.setString("hello", forType: .string)
    store.paste(from: pasteboard)
    #expect(store.files.count == 1)
    #expect(store.files[0].pathExtension == "txt")
    #expect(try String(contentsOf: store.files[0], encoding: .utf8) == "hello")

    // Web link → .webloc named after the host, holding the URL
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(string: "https://example.com/page")! as NSURL])
    store.paste(from: pasteboard)
    let webloc = try #require(store.files.last)
    #expect(webloc.lastPathComponent == "example.com.webloc")
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: webloc), format: nil) as? [String: String]
    #expect(plist?["URL"] == "https://example.com/page")

    // File → copied in, original kept; pasting a tray file again doesn't duplicate it
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("notchd-src-\(UUID().uuidString).md")
    try Data("# doc".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    pasteboard.clearContents()
    pasteboard.writeObjects([source as NSURL])
    store.paste(from: pasteboard)
    #expect(store.files.count == 3)
    #expect(FileManager.default.fileExists(atPath: source.path))
    store.add([store.files[2]])
    #expect(store.files.count == 3)

    // Rename keeps the selection and refuses slashes
    let doc = store.files[2]
    store.selection = [doc]
    let renamed = try #require(store.rename(doc, to: "Notes.md"))
    #expect(renamed.lastPathComponent == "Notes.md")
    #expect(store.selection == [renamed])
    #expect(store.rename(renamed, to: "a/b") == nil)

    // A file moved out (Option-drag) disappears from the list
    try FileManager.default.removeItem(at: renamed)
    store.reconcile()
    #expect(store.files.count == 2)
    #expect(store.selection.isEmpty)
}
