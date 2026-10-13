import Foundation
@testable import Notchd
import Testing

@Test func timerRemaining() {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    var entry = TimerEntry(seconds: 90, now: t0)
    #expect(entry.remaining(at: t0.addingTimeInterval(30)) == 60)
    #expect(entry.remaining(at: t0.addingTimeInterval(200)) == 0)   // never negative

    entry.state = .paused
    entry.remaining = 42
    #expect(entry.remaining(at: t0.addingTimeInterval(500)) == 42)  // frozen while paused

    entry.state = .expired
    #expect(entry.remaining(at: t0) == 0)
}

@Test func timerFormat() {
    #expect(TimersStore.format(65, showSeconds: true) == "1:05")
    #expect(TimersStore.format(0.2, showSeconds: true) == "0:01")      // rounds up, never shows 0 early
    #expect(TimersStore.format(3725, showSeconds: true) == "1:02:05")
    #expect(TimersStore.format(61, showSeconds: false) == "2 min")
    #expect(TimersStore.format(3600, showSeconds: false) == "1h00")
}
