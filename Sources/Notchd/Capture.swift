import AppKit
import SwiftUI

extension Notification.Name {
    static let captureVisibilityChanged = Notification.Name("captureVisibilityChanged")
    static let captureSaved = Notification.Name("captureSaved")
}

enum CaptureKind {
    case screenshot, recording

    var title: String { self == .screenshot ? "Screenshot" : "Screen Recording" }
    var fileExtension: String { self == .screenshot ? "png" : "mov" }

    func arguments(output: URL) -> [String] {
        switch self {
        case .screenshot: ["-i", "-x", "-t", "png", output.path]
        case .recording: ["-v", "-i", "-U", "-J", "video", output.path]
        }
    }
}

/// Each capture owns a staging directory. It is removed only after delivery or cancellation.
struct CaptureJob {
    enum Outcome {
        case saved(URL), cancelled
        case failed(String, recoveryFile: URL?)
    }

    let directory: URL
    let output: URL
    let log: URL

    init(kind: CaptureKind, root: URL = URL.appSupport.appendingPathComponent("Captures")) throws {
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        output = directory.appendingPathComponent("\(kind.title) \(formatter.string(from: Date())).\(kind.fileExtension)")
        log = directory.appendingPathComponent("capture.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try Data().write(to: log) }
        catch { cleanUp(); throw error }
    }

    func finish(status: Int32, diagnostics: String, tray: TrayStore) -> Outcome {
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if bytes > 0 {
            guard status == 0 else {
                return .failed("The capture did not finish successfully. The original file has been kept so you can recover it.", recoveryFile: output)
            }
            do {
                let saved = try tray.importCapture(from: output)
                cleanUp()
                return .saved(saved)
            } catch {
                return .failed("Your capture was saved, but couldn’t be added to the tray. The original has been kept. \(error.localizedDescription)", recoveryFile: output)
            }
        }
        cleanUp()
        let detail = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.localizedCaseInsensitiveContains("cancel") || (detail.isEmpty && (status == 0 || status == 1)) {
            return .cancelled
        }
        return .failed("macOS couldn’t complete the capture. Check Notchd’s access in System Settings → Privacy & Security → Screen Recording, then try again.\n\n\(detail)", recoveryFile: nil)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Observable
final class CaptureManager {
    static let shared = CaptureManager()
    private(set) var isActive = false
    private var process: Process?

    func start(_ kind: CaptureKind, displayID: CGDirectDisplayID) {
        guard !isActive else { return }
        let job: CaptureJob
        let log: FileHandle
        do {
            job = try CaptureJob(kind: kind)
            log = try FileHandle(forWritingTo: job.log)
        } catch {
            showError("Couldn’t prepare a capture", message: error.localizedDescription)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = kind.arguments(output: job.output)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = log
        task.terminationHandler = { [weak self] task in
            try? log.close()
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.setActive(false)
                let diagnostics = (try? String(contentsOf: job.log, encoding: .utf8)) ?? ""
                switch job.finish(status: task.terminationStatus, diagnostics: diagnostics, tray: .shared) {
                case .saved:
                    NotificationCenter.default.post(name: .captureSaved, object: nil, userInfo: ["displayID": displayID])
                case .cancelled: break
                case let .failed(message, recoveryFile):
                    self.showError("Couldn’t finish capture", message: message, recoveryFile: recoveryFile)
                }
            }
        }
        process = task
        setActive(true)
        // Allow the notch panels to disappear before macOS snapshots the desktop for selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            do {
                try task.run()
            } catch {
                try? log.close()
                job.cleanUp()
                self?.process = nil
                self?.setActive(false)
                self?.showError("Couldn’t start capture", message: error.localizedDescription)
            }
        }
    }

    private func setActive(_ active: Bool) {
        isActive = active
        NotificationCenter.default.post(name: .captureVisibilityChanged, object: nil)
    }

    private func showError(_ title: String, message: String, recoveryFile: URL? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let recoveryFile {
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([recoveryFile])
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

struct CaptureWidget: View {
    let model: NotchModel
    @Bindable private var capture = CaptureManager.shared

    var body: some View {
        VStack(spacing: 8) {
            captureButton("Screenshot", icon: "camera", kind: .screenshot)
            captureButton("Record screen", icon: "record.circle", kind: .recording)
            Text("Saves to your tray").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .disabled(capture.isActive)
    }

    private func captureButton(_ title: String, icon: String, kind: CaptureKind) -> some View {
        Button { capture.start(kind, displayID: model.displayID) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(BouncyButtonStyle())
        .help(kind == .screenshot ? "Select an area; press Space for a window or Escape to cancel" : "Choose an area, click Record, then use Stop in the menu bar")
    }
}
