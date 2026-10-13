@testable import Notchd
import Testing

private func r(_ percent: Int, ac: Bool, charged: Bool = false) -> PowerReading {
    PowerReading(percent: percent, onAC: ac, charged: charged)
}

@Test func batteryTransitions() {
    let prefs = Prefs()  // threshold 20, every event on
    let event = { BatteryMonitor.event(from: $0, to: $1, prefs: prefs) }

    #expect(event(nil, r(50, ac: true)) == nil)                        // launch
    #expect(event(r(50, ac: false), r(50, ac: true)) == .plugged)
    #expect(event(r(50, ac: true), r(50, ac: false)) == .unplugged)
    #expect(event(r(99, ac: true), r(100, ac: true, charged: true)) == .full)
    #expect(event(r(100, ac: true, charged: true), r(100, ac: true, charged: true)) == nil)  // already full
    #expect(event(r(21, ac: false), r(20, ac: false)) == .low)
    #expect(event(r(20, ac: false), r(19, ac: false)) == nil)          // only once per crossing
    #expect(event(r(60, ac: false), r(59, ac: false)) == nil)          // plain 1% drop

    var quiet = prefs
    quiet.batteryShowPlugged = false
    quiet.batteryShowLow = false
    #expect(BatteryMonitor.event(from: r(50, ac: false), to: r(50, ac: true), prefs: quiet) == nil)
    #expect(BatteryMonitor.event(from: r(21, ac: false), to: r(20, ac: false), prefs: quiet) == nil)
}
