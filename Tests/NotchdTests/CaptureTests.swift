import Foundation
@testable import Notchd
import Testing

@Test(arguments: [CaptureKind.screenshot, .recording])
func finishedCapturesAppearSelectedInTray(kind: CaptureKind) throws {
    let fixture = try CaptureFixture(kind: kind)
    fixture.preferences.settings.prefs.trayMoveOnDrop = true
    let contents = Data("complete capture".utf8)
    try contents.write(to: fixture.job.output)
    // Existing names must not be overwritten.
    let existing = fixture.tray.folder.appendingPathComponent(fixture.job.output.lastPathComponent)
    try Data("existing capture".utf8).write(to: existing)
    fixture.tray.reload()
    guard case let .saved(file) = fixture.job.finish(status: 0, diagnostics: "", tray: fixture.tray) else {
        Issue.record("Expected capture delivery"); return
    }
    #expect(file != existing)
    #expect(try Data(contentsOf: file) == contents)
    #expect(try String(contentsOf: existing, encoding: .utf8) == "existing capture")
    #expect(fixture.tray.selection == [file])
    #expect(fixture.tray.files.count == 2)
    #expect(!FileManager.default.fileExists(atPath: fixture.job.directory.path))
}

@Test(arguments: ["", "User cancelled selection"])
func cancelledCaptureDoesNotCreateTrayItem(diagnostics: String) throws {
    let fixture = try CaptureFixture()
    try Data().write(to: fixture.job.output)
    guard case .cancelled = fixture.job.finish(status: 1, diagnostics: diagnostics, tray: fixture.tray) else {
        Issue.record("Expected cancellation"); return
    }
    #expect(fixture.tray.files.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.job.directory.path))
}

@Test func captureImportFailureKeepsRecoverableOriginalAndCleansPartialCopy() throws {
    let manager = FailingCaptureFileManager()
    let fixture = try CaptureFixture(fileManager: manager)
    try Data("original capture".utf8).write(to: fixture.job.output)
    guard case let .failed(_, recoveryFile) = fixture.job.finish(status: 0, diagnostics: "", tray: fixture.tray) else {
        Issue.record("Expected recoverable failure"); return
    }
    #expect(recoveryFile == fixture.job.output)
    #expect(try String(contentsOf: fixture.job.output, encoding: .utf8) == "original capture")
    #expect(fixture.tray.files.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.tray.folder.path).isEmpty)
}

@Test func unsuccessfulRecordingPreservesOutputWithoutImportingIt() throws {
    let fixture = try CaptureFixture(kind: .recording)
    try Data("recoverable movie".utf8).write(to: fixture.job.output)
    guard case let .failed(_, recoveryFile) = fixture.job.finish(status: 2, diagnostics: "interrupted", tray: fixture.tray) else {
        Issue.record("Expected recoverable failure"); return
    }
    #expect(recoveryFile == fixture.job.output)
    #expect(FileManager.default.fileExists(atPath: fixture.job.output.path))
    #expect(fixture.tray.files.isEmpty)
}

@Test func deniedCaptureReportsFailureWithoutLeavingEmptyFiles() throws {
    let fixture = try CaptureFixture()
    guard case let .failed(message, recoveryFile) = fixture.job.finish(status: 1, diagnostics: "could not create image from display", tray: fixture.tray) else {
        Issue.record("Expected capture failure"); return
    }
    #expect(message.contains("Screen Recording"))
    #expect(recoveryFile == nil)
    #expect(fixture.tray.files.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.job.directory.path))
}

@Test func crashedCaptureIsNotTreatedAsCancellation() throws {
    let fixture = try CaptureFixture()
    guard case .failed = fixture.job.finish(status: 9, diagnostics: "", tray: fixture.tray) else {
        Issue.record("Unexpected process failures must be reported"); return
    }
    #expect(fixture.tray.files.isEmpty)
}

private final class FailingCaptureFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        try Data("partial copy".utf8).write(to: destination)
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

private final class CaptureFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("notchd-capture-tests-\(UUID().uuidString)")
    let preferences = TestPreferences()
    let job: CaptureJob
    let tray: TrayStore

    init(kind: CaptureKind = .screenshot, fileManager: FileManager = .default) throws {
        job = try CaptureJob(kind: kind, root: root.appendingPathComponent("captures"))
        tray = TrayStore(folder: root.appendingPathComponent("tray"), settings: preferences.settings, fileManager: fileManager)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
