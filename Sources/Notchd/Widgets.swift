import EventKit
import SwiftUI

// MARK: - To-do

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
}

@Observable
final class TodoStore {
    static let shared = TodoStore()
    private let file = URL.appSupport.appendingPathComponent("todos.json")

    var items: [TodoItem] = [] {
        didSet { try? JSONEncoder().encode(items).write(to: file, options: .atomic) }
    }

    init() {
        items = (try? JSONDecoder().decode([TodoItem].self, from: Data(contentsOf: file))) ?? []
    }
}

struct TodoWidget: View {
    @Bindable var model: NotchModel
    @Bindable private var store = TodoStore.shared
    @Local private var draft = ""
    @FocusState private var focused: Bool

    init(model: NotchModel) { self.model = model }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                TextField("New task", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(add)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Pill().fill(.white.opacity(0.08)))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach($store.items) { $item in
                        TodoRow(item: $item)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .scale(scale: 0.6).combined(with: .opacity)))
                    }
                }
            }
        }
        .onChange(of: focused) { _, value in
            model.typing = value
            if value, Settings.shared.prefs.lockWhileTyping {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { model.locked = true }
            }
        }
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.68)) {
            store.items.insert(TodoItem(title: title), at: 0)
        }
        draft = ""
    }
}

private struct TodoRow: View {
    @Binding var item: TodoItem

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { item.done.toggle() }
                Haptics.tap()
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(item.done ? .green : .secondary)
            }
            .buttonStyle(BouncyButtonStyle())
            Text(item.title)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
        .contextMenu {
            Button("Delete", role: .destructive) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    TodoStore.shared.items.removeAll { $0.id == item.id }
                }
            }
        }
    }
}

// MARK: - Calendar

/// The event driving the calendar live activity.
struct UpcomingEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var color: Color
    var meetingURL: URL?
}

@Observable
final class CalendarStore {
    static let shared = CalendarStore()
    private let store = EKEventStore()
    private(set) var events: [EKEvent] = []
    private(set) var denied = false
    /// Event starting soon (or in progress), per the calendar activity settings.
    private(set) var upcoming: UpcomingEvent?

    /// Video-call links found in an event's URL, location or notes.
    private static let meetingPatterns = [
        #"https?://meet\.google\.com/[a-zA-Z0-9-]+(?:[?#][\w=&.%-]+)?"#,
        #"https?://[\w.-]+\.zoom\.us/(?:j|my)/[\w?=&.%-]+"#,
        #"https://teams\.microsoft\.com/l/meetup-join/[\w\-%.]+/[\w:]+\?[\w=&%.]+"#,
        #"https?://[\w.-]+\.webex\.com/(?:[\w.-]+/)?(?:j\.php\?MTID=[\w]+|meet/[\w]+)(?:[?#][\w=&%.]+)?"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func meetingURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        for regex in meetingPatterns {
            if let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshUpcoming() }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.denied = !granted
                self?.reload()
            }
        }
    }

    func reload() {
        guard !denied else { return }
        let start = Date(), end = Calendar.current.startOfDay(for: start).addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        refreshUpcoming()
    }

    func refreshUpcoming() {
        let prefs = Settings.shared.prefs
        let now = Date()
        var next: UpcomingEvent?

        // Dev: `--args -debugFakeEvent YES` fakes a Meet call starting in 5 minutes.
        if UserDefaults.standard.bool(forKey: "debugFakeEvent") {
            next = UpcomingEvent(title: "Standup", start: now.addingTimeInterval(300), end: now.addingTimeInterval(1200),
                                 color: .orange, meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        } else if !denied {
            let window = prefs.calendarMinutesBefore * 60
            let candidates = store.events(matching: store.predicateForEvents(
                withStart: now, end: now.addingTimeInterval(window), calendars: nil))
            next = candidates
                .filter { !$0.isAllDay && $0.endDate > now }
                .filter { $0.startDate > now || prefs.calendarShowDuringEvent }
                .map { event in
                    let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
                    return UpcomingEvent(title: event.title ?? "", start: event.startDate, end: event.endDate,
                                         color: Color(cgColor: event.calendar.cgColor), meetingURL: Self.meetingURL(in: text))
                }
                .filter { $0.meetingURL != nil || !prefs.calendarOnlyMeetings }
                .min { $0.start < $1.start }
        }
        if next != upcoming {
            withAnimation(next == nil ? .notchClose : .notchOpen) { upcoming = next }
        }
    }
}

struct CalendarWidget: View {
    private var calendar = CalendarStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date.now, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .textCase(.uppercase)
                Text(Date.now, format: .dateTime.day())
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if calendar.denied {
                        Text("Calendar access needed").foregroundStyle(.secondary)
                    } else if calendar.events.isEmpty {
                        Text("Nothing for today").foregroundStyle(.secondary)
                    }
                    ForEach(calendar.events, id: \.eventIdentifier) { event in
                        HStack(spacing: 6) {
                            Capsule().fill(Color(cgColor: event.calendar.cgColor)).frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title ?? "").lineLimit(1)
                                Text(event.startDate, format: .dateTime.hour().minute())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { calendar.reload() }
    }
}

// MARK: - Calendar live activity

extension UpcomingEvent {
    static let sample = UpcomingEvent(title: "Standup", start: .now.addingTimeInterval(300),
                                      end: .now.addingTimeInterval(1200), color: .orange,
                                      meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
}

/// Join button for meetings (green, bouncy), otherwise a calendar glyph in the calendar's color.
struct CalendarActivityLeading: View {
    let event: UpcomingEvent

    var body: some View {
        if let url = event.meetingURL {
            Button {
                NSWorkspace.shared.open(url)
                Haptics.tap()
            } label: {
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 20)
                    .background(Pill().fill(.green))
            }
            .buttonStyle(BouncyButtonStyle())
            .help("Join \(event.title)")
        } else {
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(event.color)
        }
    }
}

/// "5m" before the event; remaining or elapsed time during it.
struct CalendarActivityTrailing: View {
    let event: UpcomingEvent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            let text: String = if event.start > now {
                Self.format(event.start.timeIntervalSince(now))
            } else if Settings.shared.prefs.calendarShowElapsed {
                Self.format(now.timeIntervalSince(event.start))
            } else {
                Self.format(event.end.timeIntervalSince(now))
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(event.start > now ? event.color : .green)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: text)
        }
    }

    /// Rounds up so "starts in 30s" reads 1m, never 0m.
    static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes < 60 ? "\(minutes)m" : String(format: "%dh%02d", minutes / 60, minutes % 60)
    }
}
