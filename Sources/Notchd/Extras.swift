import AVFoundation
import AppKit
import SwiftUI

// MARK: - Shortcuts

/// The user's Shortcuts, listed and run through the `shortcuts` command-line tool.
@Observable
final class ShortcutsStore {
    static let shared = ShortcutsStore()
    private(set) var available: [String] = []
    private(set) var running: Set<String> = []

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = Self.shortcuts(["list"])
            let names = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            DispatchQueue.main.async { self.available = names }
        }
    }

    func run(_ name: String) {
        guard !running.contains(name) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { _ = running.insert(name) }
        // The name is passed as a plain argument, never through a shell.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.shortcuts(["run", name])
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { _ = self.running.remove(name) }
            }
        }
    }

    private static func shortcuts(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct ShortcutsWidget: View {
    private var store = ShortcutsStore.shared

    var body: some View {
        let chosen = Settings.shared.prefs.shortcuts
        Group {
            if chosen.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                    Button("Choose Shortcuts…") { SettingsWindowController.shared.show(pane: .widgets) }
                        .buttonStyle(BouncyButtonStyle())
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Pill().fill(.white.opacity(0.1)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
                        ForEach(chosen, id: \.self) { name in
                            ShortcutButton(name: name, running: store.running.contains(name)) { store.run(name) }
                        }
                    }
                }
            }
        }
    }
}

private struct ShortcutButton: View {
    let name: String
    let running: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            VStack(spacing: 4) {
                Group {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill").font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(height: 18)
                Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(running ? Color.accentColor.opacity(0.35) : .white.opacity(0.08)))
        }
        .buttonStyle(BouncyButtonStyle())
        .help(Text("Run “\(name)”"))
    }
}

// MARK: - Mirror

/// A quick look at yourself before a call. The camera only runs while the mirror is on screen.
final class Camera {
    static let shared = Camera()
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "notchd.camera")
    private var input: AVCaptureDeviceInput?

    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// Asks for camera access the first time.
    static func authorize(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start(deviceID: String?) {
        queue.async { [self] in
            let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
            guard let device else { return }
            session.beginConfiguration()
            if let input, input.device != device {
                session.removeInput(input)
                self.input = nil
            }
            if input == nil, let new = try? AVCaptureDeviceInput(device: device), session.canAddInput(new) {
                session.addInput(new)
                input = new
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }
}

struct MirrorWidget: View {
    @Bindable var model: NotchModel
    @Local private var on = false
    @Local private var denied = false

    init(model: NotchModel) { self.model = model }

    var body: some View {
        let prefs = Settings.shared.prefs
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.06))
                if on {
                    CameraPreview(flip: prefs.mirrorFlip)
                        .transition(.blurPop)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: denied ? "video.slash.fill" : "web.camera.fill").font(.system(size: 22))
                        Text(denied ? "Camera access needed" : "Mirror")
                            .font(.system(size: 11, weight: .semibold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(BouncyButtonStyle())
        .onChange(of: model.isOpen) { _, open in if !open { stop() } }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        Haptics.tap()
        if on { return stop() }
        Camera.authorize { ok in
            denied = !ok
            guard ok else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                return
            }
            Camera.shared.start(deviceID: Settings.shared.prefs.mirrorCamera)
            withAnimation(.notchOpen) { on = true }
        }
    }

    private func stop() {
        Camera.shared.stop()
        withAnimation(.notchClose) { on = false }
    }
}

struct CameraPreview: NSViewRepresentable {
    let flip: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: Camera.shared.session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    /// Flipping the layer works before the session has a connection, unlike connection mirroring.
    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.setAffineTransform(CGAffineTransform(scaleX: flip ? -1 : 1, y: 1))
    }
}
