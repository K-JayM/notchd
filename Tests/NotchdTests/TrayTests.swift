import AppKit
@testable import Notchd
import Testing

@Test func trayPasteRenameReconcile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchd-tray-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let preferences = TestPreferences()
    let store = TrayStore(folder: dir, settings: preferences.settings)
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

@Test(arguments: [false, true])
func trayPasteAlwaysCopies(moveOnDrop: Bool) throws {
    let fixture = TrayFixture()
    fixture.preferences.settings.prefs.trayMoveOnDrop = moveOnDrop
    let source = fixture.root.appendingPathComponent("original.txt")
    try Data("original contents".utf8).write(to: source)
    let board = NSPasteboard(name: .init("notchd-test-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.writeObjects([source as NSURL])

    fixture.store.paste(from: board)

    #expect(try String(contentsOf: source, encoding: .utf8) == "original contents")
    let pasted = try #require(fixture.store.files.first)
    #expect(try String(contentsOf: pasted, encoding: .utf8) == "original contents")
    fixture.store.paste(from: board)
    #expect(fixture.store.files.count == 2)
    #expect(fixture.preferences.settings.prefs.trayMoveOnDrop == moveOnDrop)
}

@Test(arguments: [false, true])
func trayDropRespectsMovePreference(moveOnDrop: Bool) throws {
    let fixture = TrayFixture()
    fixture.preferences.settings.prefs.trayMoveOnDrop = moveOnDrop
    let source = fixture.root.appendingPathComponent("dropped.txt")
    try Data("drop contents".utf8).write(to: source)

    fixture.store.add([source])

    #expect(FileManager.default.fileExists(atPath: source.path) == !moveOnDrop)
    let dropped = try #require(fixture.store.files.first)
    #expect(try String(contentsOf: dropped, encoding: .utf8) == "drop contents")
}

@Test func trayFolderChangePreservesContentsAndSurvivesRestart() throws {
    let fixture = TrayFixture()
    let original = try fixture.addFile("notes.txt", text: "my notes")
    let directory = fixture.source.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("nested file".utf8).write(to: directory.appendingPathComponent("readme.txt"))
    fixture.store.reload()
    fixture.store.selection = [original]
    fixture.store.previewURL = original
    fixture.store.renaming = original
    try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: true)
    let existing = fixture.target.appendingPathComponent("notes.txt")
    try Data("existing destination file".utf8).write(to: existing)

    #expect(fixture.store.setFolder(fixture.target))

    let moved = fixture.target.appendingPathComponent("notes 2.txt")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "existing destination file")
    #expect(try String(contentsOf: moved, encoding: .utf8) == "my notes")
    #expect(try String(contentsOf: fixture.target.appendingPathComponent("Project/readme.txt"), encoding: .utf8) == "nested file")
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(fixture.store.selection == [moved])
    #expect(fixture.store.previewURL == moved)
    #expect(fixture.store.renaming == nil)
    #expect(fixture.store.folderChangeNotice == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).count == 3)

    let restarted = TrayStore(settings: Settings(defaults: fixture.preferences.defaults))
    #expect(restarted.folder == fixture.target)
    #expect(Set(restarted.files) == Set(fixture.store.files))
}

@Test func trayFolderChangeRejectsInvalidDestination() throws {
    let fixture = TrayFixture()
    let original = try fixture.addFile("keep.txt")
    try Data("not a folder".utf8).write(to: fixture.target)

    #expect(!fixture.store.setFolder(fixture.target))

    try fixture.expectOriginalTray([original])
    #expect(try String(contentsOf: fixture.target, encoding: .utf8) == "not a folder")
}

@Test(arguments: [MigrationFailure.copy, .publish])
func trayFolderChangeRollsBackPartialFailure(failure: MigrationFailure) throws {
    let manager = FailingMigrationFileManager()
    let fixture = TrayFixture(fileManager: manager)
    let originals = try [fixture.addFile("one.txt"), fixture.addFile("two.txt")]
    fixture.store.selection = Set(originals)
    fixture.store.previewURL = originals[0]
    try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: true)
    let existing = fixture.target.appendingPathComponent("existing.txt")
    try Data("keep destination data".utf8).write(to: existing)
    manager.failure = failure

    #expect(!fixture.store.setFolder(fixture.target))

    try fixture.expectOriginalTray(originals)
    #expect(fixture.store.selection == Set(originals))
    #expect(fixture.store.previewURL == originals[0])
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path) == ["existing.txt"])
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep destination data")
}

@Test func trayFolderChangeKeepsOriginalsWhenRollbackCleanupFails() throws {
    let manager = FailingMigrationFileManager()
    let fixture = TrayFixture(fileManager: manager)
    let originals = try [fixture.addFile("one.txt"), fixture.addFile("two.txt")]
    manager.failure = .publish
    manager.blockedRemovalParent = fixture.target

    #expect(!fixture.store.setFolder(fixture.target))

    try fixture.expectOriginalTray(originals)
    #expect(fixture.store.folderChangeNotice?.message.contains("extra copies") == true)
    #expect(fixture.store.folderChangeNotice?.message.contains(fixture.target.path) == true)
}

@Test func trayFolderChangeReportsOriginalCleanupFailure() throws {
    let manager = FailingMigrationFileManager()
    let fixture = TrayFixture(fileManager: manager)
    let original = try fixture.addFile("keep.txt")
    manager.blockedRemovalParent = fixture.source

    #expect(fixture.store.setFolder(fixture.target))

    #expect(try String(contentsOf: original, encoding: .utf8) == "fixture contents")
    let moved = try #require(fixture.store.files.first)
    #expect(try String(contentsOf: moved, encoding: .utf8) == "fixture contents")
    #expect(fixture.store.folderChangeNotice?.message.contains(original.path) == true)
    let restarted = TrayStore(settings: Settings(defaults: fixture.preferences.defaults))
    #expect(restarted.folder == fixture.target)
    #expect(restarted.files == [moved])
}

@Test func trayFolderChangeRejectsNestedLocationsAndRecognizesAliases() throws {
    let fixture = TrayFixture()
    let original = try fixture.addFile("keep.txt")
    #expect(!fixture.store.setFolder(fixture.source.appendingPathComponent("nested")))
    try fixture.expectOriginalTray([original])
    #expect(!fixture.store.setFolder(fixture.root))
    try fixture.expectOriginalTray([original])

    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
    #expect(fixture.store.setFolder(alias))
    #expect(fixture.store.folder == fixture.source)
    #expect(fixture.store.files == [original])
    #expect(fixture.store.folderChangeNotice == nil)
}

enum MigrationFailure: Sendable { case copy, publish }

private final class FailingMigrationFileManager: FileManager, @unchecked Sendable {
    var failure: MigrationFailure?
    var blockedRemovalParent: URL?
    private var copies = 0
    private var moves = 0

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        copies += 1
        if failure == .copy, copies == 2 {
            // A failed directory copy can leave partially written output behind.
            try Data("partial copy".utf8).write(to: dstURL)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moves += 1
        if failure == .publish, moves == 2 { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        if URL.deletingLastPathComponent() == blockedRemovalParent { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}

private final class TrayFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("notchd-tray-\(UUID().uuidString)", isDirectory: true)
    let preferences = TestPreferences()
    let source: URL
    let target: URL
    let store: TrayStore

    init(fileManager: FileManager = .default) {
        source = root.appendingPathComponent("source", isDirectory: true)
        target = root.appendingPathComponent("target", isDirectory: true)
        preferences.settings.prefs.trayFolder = source.path
        store = TrayStore(folder: source, settings: preferences.settings, fileManager: fileManager)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func addFile(_ name: String, text: String = "fixture contents") throws -> URL {
        let file = source.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        store.reload()
        return file
    }

    func expectOriginalTray(_ originals: [URL]) throws {
        #expect(store.folder == source)
        #expect(preferences.settings.prefs.trayFolder == source.path)
        #expect(Set(store.files) == Set(originals))
        for file in originals { #expect(try String(contentsOf: file, encoding: .utf8) == "fixture contents") }
        #expect(store.folderChangeNotice != nil)
        let restarted = TrayStore(settings: Settings(defaults: preferences.defaults))
        #expect(restarted.folder == source)
        #expect(Set(restarted.files) == Set(originals))
    }
}
