import AppKit
import SwiftUI

/// First-launch tour: the four basic gestures.
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func showIfFirstLaunch() {
        guard !Settings.shared.prefs.didShowWelcome else { return }
        show()
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView { [weak self] in self?.close() })
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        Settings.shared.prefs.didShowWelcome = true
        window?.close()
    }
}

private struct WelcomeView: View {
    let done: () -> Void
    @Local private var shownTips = 0

    private let tips: [(icon: String, text: String)] = [
        ("arrow.left.and.right", "Swipe sideways over the notch to skip tracks."),
        ("arrow.up.and.down", "Swipe down to open it, up to close it or tuck an activity away."),
        ("cursorarrow.click.2", "Click the notch to see your widgets."),
        ("doc.on.doc", "Drop files on it to stash them in the Tray or send them with AirDrop."),
    ]

    var body: some View {
        VStack(spacing: 22) {
            BreathingNotch()
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text("Welcome to Notchd!").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Your notch, but alive.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                    if index < shownTips {
                        HStack(spacing: 14) {
                            Image(systemName: tip.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.tint.opacity(0.15)))
                                .symbolEffect(.bounce, value: shownTips)
                            Text(L(tip.text))
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    }
                }
            }
            .frame(width: 360, height: 4 * 34 + 3 * 14, alignment: .top)
            HStack {
                Button("Open Settings") {
                    done()
                    SettingsWindowController.shared.show()
                }
                Spacer()
                Button("Get Started", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 440)
        .task {
            // Tips pop in one after another.
            for i in 1...tips.count {
                try? await Task.sleep(for: .milliseconds(i == 1 ? 350 : 220))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { shownTips = i }
            }
        }
    }
}

/// A little notch that opens and closes on a loop, with the same springs as the real one.
private struct BreathingNotch: View {
    var body: some View {
        PhaseAnimator([false, true]) { open in
            NotchShape(topRadius: open ? 10 : 5, bottomRadius: open ? 18 : 8)
                .fill(.black)
                .frame(width: open ? 220 : 110, height: open ? 70 : 22)
                .overlay(alignment: .center) {
                    if open {
                        HStack(spacing: 8) {
                            Image(systemName: "music.note")
                            Image(systemName: "calendar")
                            Image(systemName: "checklist")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.blurPop)
                    }
                }
                .frame(height: 70, alignment: .top)
        } animation: { open in
            open ? .notchOpen.delay(0.9) : .notchClose.delay(1.6)
        }
    }
}
