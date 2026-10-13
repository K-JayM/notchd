import AppKit
import CoreImage
import SwiftUI

struct NowPlaying: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var bundleID = ""
    var playing = false
    var duration: Double = 0
    var elapsed: Double = 0
    var timestamp = Date()
    var artwork: NSImage?
    var tint: Color = .white

    /// Playback position now, extrapolated from the last report.
    func position(at date: Date) -> Double {
        guard playing else { return elapsed }
        return min(duration, elapsed + date.timeIntervalSince(timestamp))
    }

    static let sample = NowPlaying(title: "Song Title", artist: "Artist", playing: true, duration: 200,
                                   elapsed: 60, tint: .pink)
}

/// Now Playing through mediaremote-adapter: Apple's perl is entitled to MediaRemote on macOS 15.4+,
/// so it loads the bundled helper framework and streams JSON lines to us.
@Observable
final class MediaManager {
    static let shared = MediaManager()

    private(set) var nowPlaying: NowPlaying?
    /// True while the media live activity should be on screen (playing, or paused less than the timeout ago).
    private(set) var showActivity = false

    private var process: Process?
    private var state: [String: Any] = [:]
    private var buffer = Data()
    private var hideWork: DispatchWorkItem?

    private var resources: URL? { Bundle.main.resourceURL }

    func start() {
        guard let resources,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("mediaremote-adapter.pl").path)
        else { return NSLog("[Media] adapter not bundled") }
        // A killed Notchd leaves its perl child running: clean up before starting a new stream.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", resources.appendingPathComponent("mediaremote-adapter.pl").path + " .* stream"]
        try? pkill.run()
        pkill.waitUntilExit()

        let process = adapter(["stream", "--debounce=50"])
        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        // The adapter dies with its parent only if we kill it; restart it if it crashes.
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
        }
        do { try process.run() } catch { return NSLog("[Media] failed to start adapter: \(error)") }
        self.process = process
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    /// `send` command ids from the adapter: 0 play, 1 pause, 2 toggle, 4 next, 5 previous.
    func send(_ command: Int) {
        try? adapter(["send", "\(command)"]).run()
    }

    func togglePlayPause() { send(2) }
    func next() { send(4) }
    func previous() { send(5) }

    func seek(to seconds: Double) {
        try? adapter(["seek", "\(Int(seconds * 1_000_000))"]).run()
        nowPlaying?.elapsed = seconds
        nowPlaying?.timestamp = Date()
    }

    private func adapter(_ args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources!.appendingPathComponent("mediaremote-adapter.pl").path,
                             resources!.appendingPathComponent("MediaRemoteAdapter.framework").path] + args
        return process
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }
            if json["diff"] as? Bool == true {
                for (key, value) in payload {
                    if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
                }
            } else {
                state = payload
            }
            apply()
        }
    }

    private func apply() {
        guard let title = state["title"] as? String, !title.isEmpty else {
            update(nil)
            return
        }
        var info = NowPlaying()
        info.title = title
        info.artist = state["artist"] as? String ?? ""
        info.album = state["album"] as? String ?? ""
        info.bundleID = state["bundleIdentifier"] as? String ?? ""
        info.playing = state["playing"] as? Bool ?? false
        info.duration = state["duration"] as? Double ?? 0
        info.elapsed = state["elapsedTime"] as? Double ?? 0
        if let ts = state["timestamp"] as? String { info.timestamp = ISO8601DateFormatter().date(from: ts) ?? Date() }

        // Decoding artwork is the expensive bit: reuse it while the track doesn't change.
        if let current = nowPlaying, current.title == info.title, current.artist == info.artist, current.artwork != nil,
           state["artworkData"] != nil {
            info.artwork = current.artwork
            info.tint = current.tint
        } else if let base64 = state["artworkData"] as? String, let data = Data(base64Encoded: base64),
                  let image = NSImage(data: data) {
            info.artwork = image
            info.tint = image.averageColor
        }
        update(info)
    }

    private func update(_ info: NowPlaying?) {
        let wasPlaying = nowPlaying?.playing ?? false
        let songChanged = info != nil && nowPlaying != nil && (info?.title != nowPlaying?.title || info?.artist != nowPlaying?.artist)
        nowPlaying = info
        if songChanged, info?.playing == true, Settings.shared.prefs.peekOnSongChange { ActivityCenter.shared.peek() }
        let playing = info?.playing ?? false

        if playing {
            hideWork?.cancel()
            hideWork = nil
            if !showActivity { withAnimation(.notchOpen) { showActivity = true } }
        } else if showActivity, wasPlaying || info == nil, hideWork == nil, !Settings.shared.prefs.demoMode {
            let work = DispatchWorkItem { [weak self] in
                self?.hideWork = nil
                withAnimation(.notchClose) { self?.showActivity = false }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.prefs.inactivityTimeout, execute: work)
        }
    }
}

extension NSImage {
    /// Average artwork color, brightened so it reads on black.
    var averageColor: Color {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s * 1.2, 1), brightness: max(b, 0.75))
    }
}

// MARK: - Live activity views

struct MediaActivityLeading: View {
    let info: NowPlaying
    var cornerRadius = Settings.shared.prefs.albumCornerRadius

    var body: some View {
        Artwork(image: info.artwork, cornerRadius: cornerRadius * 22 / 60)
            .frame(width: 22, height: 22)
            .id(info.title)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .scaleEffect(info.playing ? 1 : 0.85)
            .opacity(info.playing ? 1 : 0.6)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: info.playing)
    }
}

struct Artwork: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct MediaEffectView: View {
    let info: NowPlaying
    var effect = Settings.shared.prefs.mediaEffect
    var colored = Settings.shared.prefs.coloredEffects

    var body: some View {
        let tint = colored ? info.tint : .white
        Group {
            switch effect {
            case .spectrograph: Spectrograph(playing: info.playing, tint: tint)
            case .waves: Waves(playing: info.playing, tint: tint)
            case .vibratingCircle: VibratingCircle(playing: info.playing, tint: tint)
            case .gif:
                if let url = GIFStore.shared.url {
                    GIFEffect(url: url, playing: info.playing)
                } else {
                    Spectrograph(playing: info.playing, tint: tint)
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
    }
}

/// Fake audio spectrograph: bars bouncing on springs. Flat when paused.
struct Spectrograph: View {
    let playing: Bool
    let tint: Color
    @Local private var levels: [CGFloat] = [0.3, 0.5, 0.4, 0.6]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 4 + 12 * (playing ? levels[i] : 0))
            }
        }
        .frame(height: 16)
        .task(id: playing) {
            while playing, !Task.isCancelled {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                    levels = levels.map { _ in .random(in: 0.15...1) }
                }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: playing)
    }
}

/// Two sine waves drifting past each other. A flat line when paused.
struct Waves: View {
    let playing: Bool
    let tint: Color
    @Local private var amplitude: CGFloat

    init(playing: Bool, tint: Color) {
        self.playing = playing
        self.tint = tint
        _amplitude = Local(initialValue: playing ? 1 : 0)
    }

    var body: some View {
        TimelineView(.animation(paused: !playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for (speed, alpha) in [(5.0, 1.0), (-3.5, 0.45)] {
                    var path = Path()
                    for x in stride(from: 0, through: size.width, by: 1) {
                        let progress = x / size.width
                        let envelope = sin(progress * .pi)  // pinned at both ends
                        let y = size.height / 2 + sin(progress * 2.4 * .pi + t * speed) * envelope * amplitude * size.height / 2.4
                        x == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                    context.stroke(path, with: .color(tint.opacity(alpha)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .frame(width: 26, height: 16)
        .onChange(of: playing) { _, value in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { amplitude = value ? 1 : 0 }
        }
    }
}

/// A dot that throbs to a fake beat.
struct VibratingCircle: View {
    let playing: Bool
    let tint: Color
    @Local private var scale: CGFloat = 0.6

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.3)).scaleEffect(scale * 1.25)
            Circle().fill(tint).scaleEffect(scale * 0.8)
        }
        .frame(width: 16, height: 16)
        .task(id: playing) {
            guard playing else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { scale = 0.5 }
                return
            }
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.4)) { scale = .random(in: 0.75...1) }
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { scale = .random(in: 0.5...0.65) }
                try? await Task.sleep(for: .milliseconds(.random(in: 150...320)))
            }
        }
    }
}

// MARK: - Nook widget

struct MediaWidget: View {
    private var media = MediaManager.shared
    @Local private var scrubbing: Double?

    var body: some View {
        let info = media.nowPlaying
        HStack(spacing: 12) {
            Artwork(image: info?.artwork, cornerRadius: Settings.shared.prefs.albumCornerRadius * 1.2)
                .frame(width: 72, height: 72)
                .scaleEffect(info?.playing == false ? 0.9 : 1)
                .shadow(color: (info?.tint ?? .clear).opacity(0.35), radius: 10)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: info?.playing)
                .id(info?.title)
                .transition(.scale(scale: 0.6).combined(with: .opacity))

            VStack(alignment: .leading, spacing: 4) {
                Text(info?.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(info?.artist ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let info, info.duration > 0 { progress(info) }
                controls(info)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: info?.title)
    }

    private func progress(_ info: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let position = scrubbing ?? info.position(at: timeline.date)
            HStack(spacing: 6) {
                Text(Self.time(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(info.tint).frame(width: geo.size.width * position / info.duration)
                    }
                    .frame(height: scrubbing == nil ? 4 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                scrubbing = min(max(0, value.location.x / geo.size.width), 1) * info.duration
                            }
                        }
                        .onEnded { _ in
                            if let scrubbing { media.seek(to: scrubbing) }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { scrubbing = nil }
                        })
                }
                .frame(height: 12)
                Text(Self.time(info.duration))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func controls(_ info: NowPlaying?) -> some View {
        HStack(spacing: 18) {
            Button(action: media.previous) { Image(systemName: "backward.fill") }
            Button(action: media.togglePlayPause) {
                Image(systemName: info?.playing == true ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 18))
            }
            Button(action: media.next) { Image(systemName: "forward.fill") }
        }
        .font(.system(size: 13))
        .buttonStyle(BouncyButtonStyle())
        .frame(maxWidth: .infinity)
        .disabled(info == nil)
    }

    private static func time(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - GIF effect

/// The user's GIF lives in Application Support so it survives the original file moving.
@Observable
final class GIFStore {
    static let shared = GIFStore()
    private let file = URL.appSupport.appendingPathComponent("media-effect.gif")
    /// Bumped on every change so views reload the image.
    private(set) var revision = 0

    var url: URL? {
        _ = revision  // observe changes
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    @discardableResult
    func install(from source: URL) -> Bool {
        try? FileManager.default.removeItem(at: file)
        defer { revision += 1 }
        do {
            try FileManager.default.copyItem(at: source, to: file)
            return true
        } catch {
            NSLog("[GIF] install failed: \(error)")
            return false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
        revision += 1
    }
}

struct GIFEffect: View {
    let url: URL
    let playing: Bool
    private var prefs: Prefs { Settings.shared.prefs }

    init(url: URL, playing: Bool) {
        self.url = url
        self.playing = playing
    }

    var body: some View {
        AnimatedImage(url: url, playing: playing, pixelPerfect: prefs.gifPixelPerfect, revision: GIFStore.shared.revision)
            .frame(width: 26 * prefs.gifScale, height: 26 * prefs.gifScale)
            .offset(x: prefs.gifOffsetX, y: prefs.gifOffsetY)
            .opacity(playing ? 1 : 0.5)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
    }
}

/// NSImageView plays GIFs natively; nearest-neighbour filtering keeps pixel art crisp.
struct AnimatedImage: NSViewRepresentable {
    let url: URL
    let playing: Bool
    let pixelPerfect: Bool
    let revision: Int

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if context.coordinator.loaded != revision || view.image == nil {
            view.image = NSImage(contentsOf: url)
            context.coordinator.loaded = revision
        }
        view.animates = playing
        let filter: CALayerContentsFilter = pixelPerfect ? .nearest : .linear
        view.layer?.magnificationFilter = filter
        view.layer?.minificationFilter = filter
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded = -1 }
}
