import SwiftUI

/// Notch silhouette: concave "ears" flaring into the menu bar on top, rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2)
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: t, y: h - b))
        p.addQuadCurve(to: CGPoint(x: t + b, y: h), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: w - t - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - t, y: h - b), control: CGPoint(x: w - t, y: h))
        p.addLine(to: CGPoint(x: w - t, y: t))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        p.closeSubpath()
        return p
    }
}

/// Content pops in from the notch: blurred, shrunk toward the top, then springs into place.
struct BlurPop: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 10 : 0)
            .scaleEffect(active ? 0.82 : 1, anchor: .top)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static let blurPop = AnyTransition.asymmetric(
        insertion: .modifier(active: BlurPop(active: true), identity: BlurPop(active: false))
            .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(0.06)),
        removal: .modifier(active: BlurPop(active: true), identity: BlurPop(active: false))
            .animation(.easeOut(duration: 0.14))
    )
}

/// Button background: capsule, or a rounded rectangle when "Prefer round buttons" is off.
struct Pill: Shape {
    var round = Settings.shared.prefs.preferRoundButtons

    func path(in rect: CGRect) -> Path {
        round ? Capsule().path(in: rect)
            : RoundedRectangle(cornerRadius: min(7, rect.height / 3), style: .continuous).path(in: rect)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Press = squish, release = bounce back.
struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

struct NotchView: View {
    @Bindable var model: NotchModel
    private var activities = ActivityCenter.shared

    init(model: NotchModel) { self.model = model }

    var body: some View {
        let activity = model.isOpen ? nil : activities.current(for: model)
        let size = model.size(activity: activity)
        let radii = model.radii(activity: activity)

        ZStack(alignment: .top) {
            if model.isOpen && Settings.shared.prefs.translucentBackground {
                // Experimental: frosted glass instead of solid black (the closed notch stays black to hide the camera).
                VisualEffectBackground().overlay(Color.black.opacity(0.35)).transition(.opacity)
            } else {
                Color.black
            }
            Group {
                if model.isOpen {
                    OpenNotchView(model: model)
                        .transition(.blurPop)
                } else if let activity {
                    ActivityView(activity: activity, notchWidth: model.closedSize.width,
                                 rowHeight: model.activityRowHeight, peeking: model.isPeeking)
                        .transition(.blurPop)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width + 2 * radii.top, height: size.height)
        .clipShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
        .shadow(color: .black.opacity(model.isOpen ? 0.55 : 0), radius: 14, y: 6)
        .contentShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
        .onTapGesture { model.open() }
        .opacity(isHiddenHandle(activity) || model.hiddenByFullscreen ? 0 : 1)
        .animation(.notchClose, value: model.hiddenByFullscreen)
        .contextMenu {
            Button("Settings…") { SettingsWindowController.shared.show() }
            Divider()
            Button("Quit Notchd") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// Transparent handle on screens without a notch: invisible until hovered.
    private func isHiddenHandle(_ activity: LiveActivity?) -> Bool {
        Settings.shared.prefs.transparentHandle && !model.hasNotch
            && !model.isOpen && !model.hovering && activity == nil
    }
}

struct ActivityView: View {
    let activity: LiveActivity
    let notchWidth: CGFloat
    var rowHeight: CGFloat = 32
    var peeking = false
    private var media = MediaManager.shared

    init(activity: LiveActivity, notchWidth: CGFloat, rowHeight: CGFloat = 32, peeking: Bool = false) {
        self.activity = activity
        self.notchWidth = notchWidth
        self.rowHeight = rowHeight
        self.peeking = peeking
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading.frame(width: NotchModel.activitySide)
                Spacer(minLength: notchWidth)
                trailing.frame(width: NotchModel.activitySide)
            }
            .frame(height: rowHeight)
            // Non-interactive: buttons ignore clicks, which then open the nook like anywhere else.
            .allowsHitTesting(Settings.shared.prefs.interactiveActivities)
            if peeking {
                GlanceLine(activity: activity)
                    .frame(height: NotchModel.peekHeight, alignment: .top)
                    .padding(.horizontal, 14)
                    .transition(.blurPop)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var leading: some View {
        switch activity {
        case .hello:
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        case .media:
            if let info = media.nowPlaying { MediaActivityLeading(info: info) }
        case .calendar:
            if let event = CalendarStore.shared.upcoming { CalendarActivityLeading(event: event) }
        case let .bluetooth(event):
            BluetoothActivityLeading(event: event)
        case .timerExpired:
            TimerActivityLeading()
        case .updateAvailable:
            UpdateActivityLeading()
        case let .tray(count):
            Image(systemName: "tray.fill")
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.bounce, value: count)
        case let .battery(percent, state):
            BatteryActivityLeading(percent: percent, state: state)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch activity {
        case .hello:
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.pink)
                .phaseAnimator([0.0, 18, -8, 18, 0]) { view, angle in
                    view.rotationEffect(.degrees(angle), anchor: .bottomTrailing)
                } animation: { _ in .spring(response: 0.18, dampingFraction: 0.5) }
        case .media:
            if let info = media.nowPlaying { MediaEffectView(info: info) }
        case .calendar:
            if let event = CalendarStore.shared.upcoming { CalendarActivityTrailing(event: event) }
        case let .bluetooth(event):
            BluetoothActivityTrailing(event: event)
        case .timerExpired:
            TimerActivityTrailing()
        case .updateAvailable:
            UpdateActivityTrailing()
        case let .tray(count):
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: count)
        case let .battery(percent, state):
            BatteryActivityTrailing(percent: percent, state: state)
        }
    }
}

struct OpenNotchView: View {
    @Bindable var model: NotchModel
    @Namespace private var tabs

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: max(model.closedSize.height, 30))
            Group {
                if model.dropping {
                    DropZonesView()
                } else if model.tab == .nook {
                    NookView(model: model)
                } else {
                    TrayView(model: model)
                }
            }
            .padding(.horizontal, Settings.shared.prefs.contentPadding)
            .padding(.vertical, Settings.shared.prefs.contentPadding * 0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.tab)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.dropping)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            tabButton(.nook, icon: "house.fill", title: "Home")
            tabButton(.tray, icon: "tray.fill", title: "Tray")
            Spacer(minLength: model.closedSize.width + 20)
            Button {
                model.close()
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
                    .background(Pill().fill(.white.opacity(0.08)))
            }
            .buttonStyle(BouncyButtonStyle())
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { model.locked.toggle() }
                Haptics.tap()
            } label: {
                Image(systemName: model.locked ? "lock.fill" : "lock.open.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.locked ? .white : .secondary)
                    .frame(width: 26, height: 22)
                    .background(Pill().fill(.white.opacity(model.locked ? 0.2 : 0.08)))
            }
            .buttonStyle(BouncyButtonStyle())
        }
        .padding(.horizontal, 14)
    }

    private func tabButton(_ tab: NotchModel.Tab, icon: String, title: String) -> some View {
        let selected = model.tab == tab && !model.dropping
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { model.tab = tab }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .white : .secondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background {
                    if selected {
                        Pill().fill(.white.opacity(0.16))
                            .matchedGeometryEffect(id: "tab", in: tabs)
                    }
                }
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

struct NookView: View {
    @Bindable var model: NotchModel

    var body: some View {
        let prefs = Settings.shared.prefs
        let shown = model.layout.shown
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    if prefs.showDividers {
                        Divider().overlay(.white.opacity(0.1)).padding(.horizontal, 14)
                    } else {
                        Spacer().frame(width: Grid.gap(dividers: false))
                    }
                }
                widget(kind)
                    .frame(width: Grid.width(units: units(kind), dividers: prefs.showDividers))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: shown)
    }

    private func units(_ kind: WidgetKind) -> Int {
        Settings.shared.prefs.widgets.first { $0.kind == kind }?.units ?? kind.defaultUnits
    }

    @ViewBuilder private func widget(_ kind: WidgetKind) -> some View {
        switch kind {
        case .media: MediaWidget()
        case .calendar: CalendarWidget()
        case .todo: TodoWidget(model: model)
        case .timer: TimerWidget()
        }
    }
}
