import AppKit
import SwiftUI

struct DownloadEvent: Equatable {
    var url: URL
    var name: String { url.lastPathComponent }

    static let sample = DownloadEvent(url: URL(fileURLWithPath: "/Users/Shared/Report.pdf"))
}

/// Watches the Downloads folder and flashes an activity when a download finishes.
/// Browsers write to a temporary name (.crdownload, .download, .part…) and rename at the end,
/// so a finished download is a new name without one of those extensions whose size has settled.
final class DownloadsMonitor {
    static let shared = DownloadsMonitor()
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var folder: URL?
    private var scanWork: DispatchWorkItem?

    static let partialExtensions: Set = ["crdownload", "download", "part", "partial", "tmp", "opdownload", "!qb",
                                         "fdmdownload", "aria2"]

    static var defaultFolder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    /// Follows the activity's on/off switch: the folder is only read while it's on.
    func apply() {
        let prefs = Settings.shared.prefs
        let wanted = prefs.isEnabled(.download) && prefs.liveActivitiesEnabled
            ? prefs.downloadsFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder : nil
        guard wanted != folder else { return }
        stop()
        folder = wanted
        guard let wanted else { return }
        known = Self.names(in: wanted)
        let fd = open(wanted.path, O_EVTONLY)
        guard fd >= 0 else { return NSLog("[Downloads] can't watch \(wanted.path)") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleScan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func stop() {
        source?.cancel()
        source = nil
    }

    private func scheduleScan() {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func scan() {
        guard let folder else { return }
        let names = Self.names(in: folder)
        let new = names.subtracting(known).filter(Self.isFinished)
        known = names
        for name in new.sorted() {
            let url = folder.appendingPathComponent(name)
            whenSettled(url) { ActivityCenter.shared.show(.download(DownloadEvent(url: url)), for: 6) }
        }
    }

    /// Waits until the file stops growing (a copy into Downloads can still be writing).
    private func whenSettled(_ url: URL, lastSize: Int = -1, tries: Int = 0, done: @escaping () -> Void) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Firefox makes the final name empty next to "name.part" until it's done.
        let partial = FileManager.default.fileExists(atPath: url.path + ".part")
        if tries >= 40 { return }
        if size > 0 || Self.isFolder(url), size == lastSize, !partial { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            self?.whenSettled(url, lastSize: size, tries: tries + 1, done: done)
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func isFinished(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !name.hasPrefix(".") && !partialExtensions.contains(ext) && !name.hasPrefix("Unconfirmed ")
    }

    static func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }
}

// MARK: - Live activity

struct DownloadActivityLeading: View {
    let event: DownloadEvent

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([event.url])
            Haptics.tap()
        } label: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: event.url.path))
                .resizable()
                .frame(width: 22, height: 22)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white, .blue)
                        .offset(x: 3, y: 3)
                }
        }
        .buttonStyle(BouncyButtonStyle())
        .help(Text("Show in Finder"))
    }
}

/// Puts the download in the tray, ready to drag somewhere else.
struct DownloadActivityTrailing: View {
    let event: DownloadEvent
    @Local private var added = false

    var body: some View {
        Button {
            TrayStore.shared.add([event.url])
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { added = true }
            Haptics.tap()
        } label: {
            Image(systemName: added ? "checkmark" : "tray.and.arrow.down.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 20)
                .background(Pill().fill(added ? Color.green : .white))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(BouncyButtonStyle())
        .disabled(added)
        .help(Text("Add to Tray"))
    }
}
