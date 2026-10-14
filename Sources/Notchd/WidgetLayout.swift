import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let notchdWidget = UTType(exportedAs: "app.notchd.widget", conformingTo: .data)
}

enum WidgetDrag {
    static func provider(for kind: WidgetKind) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = kind.title
        provider.registerDataRepresentation(forTypeIdentifier: UTType.notchdWidget.identifier, visibility: .ownProcess) { completion in
            completion(try? JSONEncoder().encode(kind), nil)
            return nil
        }
        return provider
    }
}

extension Settings {
    /// Move the existing slot so width choices survive removing and re-adding a module.
    /// A rejected drop never changes the saved layout.
    @discardableResult
    func placeWidget(_ kind: WidgetKind, before target: WidgetKind? = nil, maxUnits: Int) -> Bool {
        var slots = prefs.widgets
        guard let oldIndex = slots.firstIndex(where: { $0.kind == kind }) else { return false }
        if target == kind, slots[oldIndex].enabled { return true }
        var slot = slots.remove(at: oldIndex)
        slot.enabled = true
        let destination = target.flatMap { target in slots.firstIndex { $0.kind == target } } ?? slots.endIndex
        slots.insert(slot, at: destination)
        guard NookLayout.fit(slots, maxUnits: maxUnits).shown.contains(kind) else { return false }
        prefs.widgets = slots
        return true
    }

    func removeWidget(_ kind: WidgetKind) {
        guard let index = prefs.widgets.firstIndex(where: { $0.kind == kind }) else { return }
        prefs.widgets[index].enabled = false
    }
}

/// Use a private data type: dragging a module must never turn it into a text file in the tray.
struct WidgetDropDelegate: DropDelegate {
    var hovering: (CGPoint?) -> Void = { _ in }
    let receive: (WidgetKind, CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.notchdWidget]) }
    func dropEntered(info: DropInfo) { hovering(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        hovering(info.location)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { hovering(nil) }
    func performDrop(info: DropInfo) -> Bool {
        hovering(nil)
        guard let provider = info.itemProviders(for: [.notchdWidget]).first else { return false }
        let point = info.location
        provider.loadDataRepresentation(forTypeIdentifier: UTType.notchdWidget.identifier) { data, _ in
            guard let data, let kind = try? JSONDecoder().decode(WidgetKind.self, from: data) else { return }
            DispatchQueue.main.async { receive(kind, point) }
        }
        return true
    }
}

private struct ModuleDestination: ViewModifier {
    let receive: (WidgetKind) -> Void
    @Local private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
            .onDrop(of: [.notchdWidget], delegate: WidgetDropDelegate(
                hovering: { targeted = $0 != nil }, receive: { kind, _ in receive(kind) }))
    }
}

struct WidgetLayoutEditor: View {
    @Bindable var settings: Settings
    let maxUnits: Int
    @Local private var selection = WidgetKind.media
    @Local private var message: String?

    private var enabled: [Slot<WidgetKind>] { settings.prefs.widgets.filter(\.enabled) }
    private var layout: NookLayout { NookLayout.fit(settings.prefs.widgets, maxUnits: maxUnits) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your notch").font(.headline)
                Text("Drag modules here or onto the notch at the top of your screen. Drag a placed module to change its order.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(enabled) { slot in
                        placedModule(slot)
                            .modifier(ModuleDestination { place($0, before: slot.kind) })
                    }
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.title3)
                        Text("Drop here").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 80, height: 86)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .modifier(ModuleDestination { place($0) })
                }
                .padding(12)
            }
            .frame(height: 122)
            .background(.black, in: RoundedRectangle(cornerRadius: 22))
            .environment(\.colorScheme, .dark)

            if let message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            if !layout.hidden.isEmpty {
                Text("Some enabled modules do not fit on this screen. Move them earlier, reduce their width, or remove another module.")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text("Module library").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(WidgetKind.allCases) { kind in
                        let isEnabled = enabled.contains { $0.kind == kind }
                        Button {
                            selection = kind
                            if !isEnabled { place(kind) }
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: kind.icon).font(.title3)
                                Text(kind.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(isEnabled ? "In notch" : "Drag or click to add")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).frame(height: 82)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 124)
                        .onDrag { WidgetDrag.provider(for: kind) }
                        .help("Drag \(kind.title) into the preview or onto the notch")
                    }
                }
            }
            .frame(height: 94)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(selection.title).font(.headline)
                    if let index = settings.prefs.widgets.firstIndex(where: { $0.kind == selection }) {
                        Stepper("Width: \(settings.prefs.widgets[index].units)U",
                                value: $settings.prefs.widgets[index].units, in: selection.unitRange)
                    }
                    WidgetOptions(kind: selection)
                }
                .frame(width: 270, alignment: .leading)
                UnitsGauge(layout: layout)
            }
        }
        .padding(24)
        .frame(width: 700)
    }

    private func placedModule(_ slot: Slot<WidgetKind>) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: slot.kind.icon)
                Spacer(minLength: 2)
                Button {
                    settings.removeWidget(slot.kind)
                    message = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(slot.kind.title) from the notch")
                .accessibilityLabel("Remove \(slot.kind.title)")
            }
            Text(slot.kind.title).font(.system(size: 10, weight: .semibold)).lineLimit(2)
            Text(layout.hidden.contains(slot.kind) ? "No room" : "\(slot.units)U")
                .font(.caption2).foregroundStyle(layout.hidden.contains(slot.kind) ? .orange : .secondary)
        }
        .padding(10)
        .frame(width: CGFloat(slot.units) * 34, height: 86)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(selection == slot.kind ? 0.18 : 0.08)))
        .contentShape(Rectangle())
        .onTapGesture { selection = slot.kind }
        .onDrag { WidgetDrag.provider(for: slot.kind) }
        .help("Drag to reorder; drop another module here to insert before \(slot.kind.title)")
    }

    private func place(_ kind: WidgetKind, before target: WidgetKind? = nil) {
        if settings.placeWidget(kind, before: target, maxUnits: maxUnits) {
            selection = kind
            message = nil
        } else {
            message = "There isn’t enough room for \(kind.title) there. Remove a module or reduce its width, then try again."
        }
    }
}

extension Slot: Identifiable { var id: Kind { kind } }
