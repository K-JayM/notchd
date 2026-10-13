import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

extension URL {
    static let appSupport: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// Dropped files live in the tray folder; the folder itself is the persisted state.
@Observable
final class TrayStore {
    static let shared = TrayStore()
    static let defaultFolder = URL.appSupport.appendingPathComponent("TrayFiles", isDirectory: true)

    private(set) var files: [URL] = []
    private(set) var folder: URL
    var selection: Set<URL> = []
    /// File shown in Quick Look (Space).
    var previewURL: URL?
    /// File whose name is being edited.
    var renaming: URL?

    convenience init() {
        self.init(folder: Settings.shared.prefs.trayFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultFolder)
    }

    init(folder: URL) {
        self.folder = folder
        reload()
        // Auto-clear runs at launch and then hourly.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.autoClear() }
    }

    func reload() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: .skipsHiddenFiles)) ?? [])
            .sorted { $0.addedDate < $1.addedDate }
        autoClear()
    }

    func add(_ urls: [URL]) {
        let move = Settings.shared.prefs.trayMoveOnDrop
        // Dragging a tray file back onto the tray is a no-op, not a duplicate.
        for url in urls where url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            let target = uniqueTarget(for: url.lastPathComponent, in: folder)
            do {
                if move { try FileManager.default.moveItem(at: url, to: target) }
                else { try FileManager.default.copyItem(at: url, to: target) }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { files.append(target) }
            } catch {
                NSLog("[Tray] \(move ? "move" : "copy") failed: \(error)")
            }
        }
    }

    /// Sends to the Trash rather than deleting: the tray folder may be one the user also uses.
    func remove(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { files.removeAll { $0 == url } }
        } catch {
            NSLog("[Tray] trash failed: \(error)")
        }
    }

    func clear() { files.forEach(remove) }

    func remove(_ urls: some Sequence<URL>) {
        urls.forEach(remove)
        selection.subtract(urls)
    }

    /// Drops files that vanished from disk (moved out with an Option-drag, deleted in Finder...).
    func reconcile() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            files.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        }
        selection.formIntersection(files)
    }

    @discardableResult
    func rename(_ url: URL, to name: String) -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != url.lastPathComponent, !name.contains("/") else { return nil }
        let target = uniqueTarget(for: name, in: folder)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            if let i = files.firstIndex(of: url) { files[i] = target }
            if selection.remove(url) != nil { selection.insert(target) }
            return target
        } catch {
            NSLog("[Tray] rename failed: \(error)")
            return nil
        }
    }

    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    /// ⌘V: files are copied in; images, links and text become files.
    func paste(from pasteboard: NSPasteboard = .general) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls)
        } else if let image = NSImage(pasteboard: pasteboard) {
            add(image: image)
        } else if let url = pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL, url.scheme?.hasPrefix("http") == true {
            add(link: url)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            add(text: text)
        } else {
            NSLog("[Tray] Paste: pasteboard contained nothing usable.")
        }
    }

    func add(text: String) {
        write(Data(text.utf8), name: "Pasted Text \(Self.stamp()).txt")
    }

    func add(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        write(png, name: "Pasted Image \(Self.stamp()).png")
    }

    /// Links become .webloc files, which open in the browser and AirDrop as links.
    func add(link: URL) {
        let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0)
        let host = link.host() ?? "Link"
        if let plist { write(plist, name: "\(host).webloc") }
    }

    private func write(_ data: Data, name: String) {
        let target = uniqueTarget(for: name, in: folder)
        do {
            try data.write(to: target)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { files.append(target) }
        } catch {
            NSLog("[Tray] Failed to write \(name): \(error)")
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    /// Moves the tray (and its files) to a new folder; nil = default folder.
    func setFolder(_ newFolder: URL?) {
        let target = newFolder ?? Self.defaultFolder
        guard target.standardizedFileURL != folder.standardizedFileURL else { return }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in files {
            do {
                try FileManager.default.moveItem(at: file, to: uniqueTarget(for: file.lastPathComponent, in: target))
            } catch {
                NSLog("[Tray] could not move \(file.lastPathComponent): \(error)")  // stays in the old folder
            }
        }
        folder = target
        Settings.shared.prefs.trayFolder = newFolder?.path
        reload()
    }

    private func autoClear() {
        let days = Settings.shared.prefs.trayAutoClearDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        files.filter { $0.addedDate < cutoff }.forEach(remove)
    }

    private func uniqueTarget(for name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return target
    }
}

private extension URL {
    var addedDate: Date {
        (try? resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate) ?? .distantPast
    }
}

// MARK: - Dropped items

/// Anything that can be dropped on the notch: files, web links, text or images.
enum DroppedItem {
    case file(URL), link(URL), text(String), image(NSImage)

    static let types: [UTType] = [.fileURL, .url, .image, .plainText]

    static func load(_ providers: [NSItemProvider], completion: @escaping ([DroppedItem]) -> Void) {
        let group = DispatchGroup()
        var items = [DroppedItem?](repeating: nil, count: providers.count)
        for (i, provider) in providers.enumerated() {
            group.enter()
            let done: (DroppedItem?) -> Void = { item in
                DispatchQueue.main.async { items[i] = item; group.leave() }
            }
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    done(url.map { $0.isFileURL ? .file($0) : .link($0) })
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { image, _ in done((image as? NSImage).map { .image($0) }) }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in done(text.map { .text($0) }) }
            } else {
                done(nil)
            }
        }
        group.notify(queue: .main) { completion(items.compactMap { $0 }) }
    }

    /// What AirDrop / sharing services accept.
    var shareable: Any {
        switch self {
        case let .file(url), let .link(url): url
        case let .text(text): text
        case let .image(image): image
        }
    }
}

extension TrayStore {
    func add(_ items: [DroppedItem]) {
        add(items.compactMap { if case let .file(url) = $0 { url } else { nil } })
        for item in items {
            switch item {
            case .file: break
            case let .link(url): add(link: url)
            case let .text(text): add(text: text)
            case let .image(image): add(image: image)
            }
        }
    }
}

// MARK: - Tray tab

struct TrayView: View {
    @Bindable var model: NotchModel
    @Bindable private var store = TrayStore.shared
    @Local private var targeted = false

    init(model: NotchModel) { self.model = model }

    var body: some View {
        Group {
            if store.files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24))
                        .symbolEffect(.bounce, value: targeted)
                    Text("Drop files here, or paste with ⌘V")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.files, id: \.self) { url in
                            TrayFileView(url: url, model: model)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity)
                }
                // Clicking the empty space clears the selection.
                .background(Color.black.opacity(0.001).onTapGesture { store.selection = [] })
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(targeted ? 0.5 : 0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .overlay(alignment: .topTrailing) {
            Button { store.paste() } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
                    .background(Pill().fill(.white.opacity(0.08)))
            }
            .buttonStyle(BouncyButtonStyle())
            .help("Paste (⌘V)")
            .padding(6)
        }
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: targeted)
        .onDrop(of: DroppedItem.types, isTargeted: $targeted) { providers in
            DroppedItem.load(providers) { store.add($0) }
            Haptics.tap()
            return true
        }
        .quickLookPreview($store.previewURL, in: store.files)
    }
}

struct TrayFileView: View {
    let url: URL
    @Bindable var model: NotchModel
    private var store = TrayStore.shared
    @Local private var hovering = false
    @Local private var draftName = ""
    @FocusState private var nameFocused: Bool

    init(url: URL, model: NotchModel) {
        self.url = url
        self.model = model
    }

    var body: some View {
        let selected = store.selection.contains(url)
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 48, height: 48)
                .overlay(TrayItemInteraction(url: url, onClick: click, menu: menu))
            if store.renaming == url {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 10))
                    .frame(width: 72)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.15)))
                    .focused($nameFocused)
                    .onAppear {
                        draftName = url.lastPathComponent
                        nameFocused = true
                    }
                    .onSubmit { store.rename(url, to: draftName) }
                    .onExitCommand { store.renaming = nil }
                    .onChange(of: nameFocused) { _, focused in
                        model.typing = focused
                        if !focused, store.renaming == url { store.rename(url, to: draftName) }
                    }
            } else {
                Text(url.lastPathComponent)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor : .clear))
                    .frame(width: 72)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(selected ? 0.16 : hovering ? 0.08 : 0)))
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
        .onHover { hovering = $0 }
    }

    /// Finder-like: click selects, ⌘-click toggles, ⇧-click extends, double-click opens.
    private func click(_ modifiers: NSEvent.ModifierFlags, _ count: Int) {
        if count >= 2 {
            NSWorkspace.shared.open(url)
            return
        }
        if modifiers.contains(.command) {
            if store.selection.remove(url) == nil { store.selection.insert(url) }
        } else if modifiers.contains(.shift), let anchor = store.files.firstIndex(where: store.selection.contains),
                  let here = store.files.firstIndex(of: url) {
            store.selection.formUnion(store.files[min(anchor, here)...max(anchor, here)])
        } else {
            store.selection = [url]
        }
    }

    private func menu() -> NSMenu {
        if !store.selection.contains(url) { store.selection = [url] }
        let targets = store.files.filter(store.selection.contains)
        let menu = ClosureMenu()
        menu.add("Open") { targets.forEach { NSWorkspace.shared.open($0) } }
        menu.add("Quick Look") { store.previewURL = url }
        menu.add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        if targets.count == 1 { menu.add("Rename") { store.renaming = url } }
        menu.add("Copy") { store.copyToPasteboard(targets) }
        menu.add("Send via AirDrop") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: targets) }
        menu.addItem(.separator())
        menu.add(targets.count == 1 ? "Remove from Tray" : "Remove \(targets.count) Items from Tray") {
            store.remove(targets)
        }
        return menu
    }
}

/// NSMenu whose items run closures.
final class ClosureMenu: NSMenu {
    private var actions: [() -> Void] = []

    func add(_ title: String, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        addItem(item)
    }

    @objc private func run(_ item: NSMenuItem) { actions[item.tag]() }
}

/// AppKit drag source over a tray item: drags every selected file, copies by default and moves with
/// Option (SwiftUI's onDrag can't choose the operation or tell when the drop is done). Plain clicks and
/// right clicks are forwarded.
struct TrayItemInteraction: NSViewRepresentable {
    let url: URL
    let onClick: (NSEvent.ModifierFlags, Int) -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.url = url
        view.onClick = onClick
        view.menuProvider = menu
    }

    final class DragView: NSView, NSDraggingSource {
        var url: URL?
        var onClick: ((NSEvent.ModifierFlags, Int) -> Void)?
        var menuProvider: (() -> NSMenu)?
        private var downEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, let url else { return }
            let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,
                                 event.locationInWindow.y - down.locationInWindow.y)
            guard distance > 3 else { return }
            downEvent = nil
            let store = TrayStore.shared
            let urls = store.selection.contains(url) ? store.files.filter(store.selection.contains) : [url]
            let items = urls.enumerated().map { index, file in
                let item = NSDraggingItem(pasteboardWriter: file as NSURL)
                let offset = CGFloat(index) * 4
                item.setDraggingFrame(bounds.offsetBy(dx: offset, dy: -offset),
                                      contents: NSWorkspace.shared.icon(forFile: file.path))
                return item
            }
            beginDraggingSession(with: items, event: down, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if downEvent != nil { onClick?(event.modifierFlags, event.clickCount) }
            downEvent = nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            NSEvent.modifierFlags.contains(.option) ? .move : .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // Moved files are gone from the tray folder now.
            if operation == .move { TrayStore.shared.reconcile() }
        }
    }
}

// MARK: - Drop zones

/// Shown while something is dragged over the notch.
struct DropZonesView: View {
    var body: some View {
        HStack(spacing: 12) {
            DropZone(icon: "tray.and.arrow.down.fill", title: "Tray") { TrayStore.shared.add($0) }
            DropZone(icon: "airplayaudio", title: "AirDrop") { items in
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: items.map(\.shareable))
            }
        }
    }
}

private struct DropZone: View {
    let icon: String
    let title: String
    let action: ([DroppedItem]) -> Void
    @Local private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .symbolEffect(.bounce, value: targeted)
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(targeted ? .white : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(targeted ? 0.14 : 0.05))
                .strokeBorder(.white.opacity(targeted ? 0.45 : 0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .scaleEffect(targeted ? 1.05 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: targeted)
        .onDrop(of: DroppedItem.types, isTargeted: Binding(get: { targeted }, set: { value in
            if value && !targeted { Haptics.tap() }
            targeted = value
        })) { providers in
            DroppedItem.load(providers, completion: action)
            Haptics.tap()
            return true
        }
    }
}
