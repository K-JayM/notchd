import EventKit
import SwiftUI

// MARK: - To-do

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false {
        didSet { doneAt = done ? Date() : nil }
    }
    var starred = false
    var doneAt: Date?

    init(title: String) { self.title = title }

    // Older files lack the newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        done = try c.decode(Bool.self, forKey: .done)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
    }
}

@Observable
final class TodoStore {
    static let shared = TodoStore()
    private let file: URL

    var items: [TodoItem] = [] {
        didSet { try? JSONEncoder().encode(items).write(to: file, options: .atomic) }
    }

    init(file: URL = URL.appSupport.appendingPathComponent("todos.json")) {
        self.file = file
        items = (try? JSONDecoder().decode([TodoItem].self, from: Data(contentsOf: file))) ?? []
        clearOld()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.clearOld() }
    }

    /// Starred first, then newest first (the stored order); completed ones hidden if the user asked.
    func visible(showCompleted: Bool) -> [TodoItem] {
        items.filter { showCompleted || !$0.done }.sorted { $0.starred && !$1.starred }
    }

    /// Completed tasks go away N days after they were checked off.
    func clearOld(now: Date = .now) {
        let days = Settings.shared.prefs.todoClearAfterDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-days * 86_400)
        if items.contains(where: { $0.done && ($0.doneAt ?? .distantPast) < cutoff }) {
            items.removeAll { $0.done && ($0.doneAt ?? .distantPast) < cutoff }
        }
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
                    ForEach(store.visible(showCompleted: Settings.shared.prefs.todoShowCompleted)) { item in
                        TodoRow(item: binding(item.id))
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

    private func binding(_ id: UUID) -> Binding<TodoItem> {
        Binding(get: { store.items.first { $0.id == id } ?? TodoItem(title: "") },
                set: { new in if let i = store.items.firstIndex(where: { $0.id == id }) { store.items[i] = new } })
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
    @Local private var hovering = false

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
            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { item.starred.toggle() }
                Haptics.tap()
            } label: {
                Image(systemName: item.starred ? "star.fill" : "star")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(item.starred ? .yellow : .secondary.opacity(hovering ? 1 : 0))
            }
            .buttonStyle(BouncyButtonStyle())
            .help(Text(item.starred ? "Unstar" : "Star: keeps it on top"))
        }
        .onHover { hovering = $0 }
        .font(.system(size: 12))
        .padding(.vertical, 3)
        .contextMenu {
            Button(item.starred ? "Unstar" : "Star") { item.starred.toggle() }
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
    /// Events of `day`, per the widget settings.
    private(set) var events: [EKEvent] = []
    /// Days around today that have something on them.
    private(set) var busyDays: Set<Date> = []
    private(set) var calendars: [EKCalendar] = []
    private(set) var denied = false
    /// Day shown in the widget.
    var day = Calendar.current.startOfDay(for: .now) {
        didSet { if day != oldValue { reload() } }
    }
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

    static func meetingURL(of event: EKEvent) -> URL? {
        meetingURL(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " "))
    }

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        // Also rolls the widget over to the new day at midnight.
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.day = Calendar.current.startOfDay(for: .now)
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshUpcoming() }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.denied = !granted
                self?.reload()
            }
        }
    }

    /// Calendars the user hasn't turned off in Settings (nil = all, which EventKit wants as nil).
    private var shownCalendars: [EKCalendar]? {
        let hidden = Settings.shared.prefs.calendarHidden
        return hidden.isEmpty ? nil : calendars.filter { !hidden.contains($0.calendarIdentifier) }
    }

    func reload() {
        guard !denied else { return }
        calendars = store.calendars(for: .event)
        let prefs = Settings.shared.prefs
        let cal = Calendar.current, now = Date()
        let shown = shownCalendars
        if shown?.isEmpty == true {
            events = []
            busyDays = []
        } else {
            let end = cal.date(byAdding: .day, value: 1, to: day)!
            events = store.events(matching: store.predicateForEvents(withStart: day, end: end, calendars: shown))
                .filter { prefs.calendarShowAllDay || !$0.isAllDay }
                .filter { prefs.calendarShowPast || !cal.isDateInToday(day) || $0.endDate > now }
                .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }

            let today = cal.startOfDay(for: now)
            let range = Int(prefs.calendarDays)
            let first = cal.date(byAdding: .day, value: -range, to: today)!
            let last = cal.date(byAdding: .day, value: range + 1, to: today)!
            var busy = Set<Date>()
            for event in store.events(matching: store.predicateForEvents(withStart: first, end: last, calendars: shown)) {
                var d = max(cal.startOfDay(for: event.startDate), first)
                while d < min(event.endDate, last) {
                    busy.insert(d)
                    d = cal.date(byAdding: .day, value: 1, to: d)!
                }
            }
            busyDays = busy
        }
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
        } else if !denied, shownCalendars?.isEmpty != true {
            let window = prefs.calendarMinutesBefore * 60
            let candidates = store.events(matching: store.predicateForEvents(
                withStart: now, end: now.addingTimeInterval(window), calendars: shownCalendars))
            next = candidates
                .filter { !$0.isAllDay && $0.endDate > now }
                .filter { $0.startDate > now || prefs.calendarShowDuringEvent }
                .map { event in
                    UpcomingEvent(title: event.title ?? "", start: event.startDate, end: event.endDate,
                                  color: Color(cgColor: event.calendar.cgColor), meetingURL: Self.meetingURL(of: event))
                }
                .filter { $0.meetingURL != nil || !prefs.calendarOnlyMeetings }
                .min { $0.start < $1.start }
        }
        if next != upcoming {
            withAnimation(next == nil ? .notchClose : .notchOpen) { upcoming = next }
        }
    }

    /// Opens the event in Calendar.
    static func open(_ event: EKEvent) {
        guard let id = event.calendarItemIdentifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct CalendarWidget: View {
    @Bindable private var calendar = CalendarStore.shared
    private var isToday: Bool { Calendar.current.isDateInToday(calendar.day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    if isToday {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                    } else {
                        goToday()
                    }
                } label: {
                    Text(calendar.day, format: .dateTime.month(.wide))
                        .font(.system(size: 13, weight: .bold))
                        .contentTransition(.numericText())
                }
                .buttonStyle(BouncyButtonStyle())
                .help(isToday ? Text("Open Calendar") : Text("Back to today"))
                Spacer()
                if !isToday {
                    Button("Today", action: goToday)
                        .buttonStyle(BouncyButtonStyle())
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Pill().fill(.white.opacity(0.1)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            DayStrip(calendar: calendar)
            eventList
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: calendar.day)
        .onAppear { calendar.reload() }
    }

    private func goToday() {
        calendar.day = Calendar.current.startOfDay(for: .now)
        Haptics.tap()
    }

    private var eventList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 5) {
                if calendar.denied {
                    Text("Calendar access needed").foregroundStyle(.secondary)
                } else if calendar.events.isEmpty {
                    Text(isToday ? "Nothing for today" : "Nothing planned").foregroundStyle(.secondary)
                }
                ForEach(calendar.events, id: \.calendarItemIdentifier) { event in
                    EventRow(event: event)
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(calendar.day)
        .transition(.blurPop)
    }
}

/// Days around today in a row; scroll sideways, click one to see its events.
private struct DayStrip: View {
    @Bindable var calendar: CalendarStore

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let range = Int(Settings.shared.prefs.calendarDays)
        let days = (-range...range).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(days, id: \.self) { day in
                        dayButton(day, today: today).id(day)
                    }
                }
            }
            .onAppear { proxy.scrollTo(calendar.day, anchor: .center) }
            .onChange(of: calendar.day) { _, day in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { proxy.scrollTo(day, anchor: .center) }
            }
        }
        .frame(height: 38)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }

    private func dayButton(_ day: Date, today: Date) -> some View {
        let selected = day == calendar.day
        let isToday = day == today
        let weekend = Calendar.current.isDateInWeekend(day)
        return Button {
            calendar.day = day
            Haptics.tap()
        } label: {
            VStack(spacing: 1) {
                Text(day, format: .dateTime.weekday(.narrow))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(selected && isToday ? .white : isToday ? .red : weekend ? .secondary : .primary.opacity(0.7))
                Text(day, format: .dateTime.day())
                    .font(.system(size: 13, weight: selected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(isToday && !selected ? .red : .primary)
                Circle()
                    .fill(calendar.busyDays.contains(day) ? Color.secondary : .clear)
                    .frame(width: 3, height: 3)
            }
            .frame(width: 26, height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? (isToday ? Color.red.opacity(0.8) : .white.opacity(0.18)) : .clear))
            .scaleEffect(selected ? 1 : 0.92)
        }
        .buttonStyle(BouncyButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
    }
}

private struct EventRow: View {
    let event: EKEvent
    @Local private var hovering = false

    var body: some View {
        let meeting = CalendarStore.meetingURL(of: event)
        HStack(spacing: 6) {
            Capsule().fill(Color(cgColor: event.calendar.cgColor)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if meeting != nil { Image(systemName: "video.fill").font(.system(size: 8)).foregroundStyle(.green) }
                    Text(event.title ?? "").lineLimit(1)
                }
                Group {
                    if event.isAllDay {
                        Text("All day")
                    } else {
                        Text(event.startDate, format: .dateTime.hour().minute())
                            + Text(" – ") + Text(event.endDate, format: .dateTime.hour().minute())
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let meeting, hovering {
                Button {
                    NSWorkspace.shared.open(meeting)
                    Haptics.tap()
                } label: {
                    Text("Join")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Pill().fill(.green))
                }
                .buttonStyle(BouncyButtonStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { CalendarStore.open(event) }
        .onHover { value in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovering = value } }
        .help(Text("Open in Calendar"))
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
