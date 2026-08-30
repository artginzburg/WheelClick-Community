import AppKit
import Darwin
import IOKit

// EnergyBench — real-world energy and performance measurements for WheelClick.
//
// Measures the live app process from the outside via proc_pid_rusage: CPU
// time, idle/interrupt wakeups, billed CPU energy (nanojoules, no sudo
// needed) and memory footprint. Load scenarios post synthetic events through
// the same session event stream the app taps, so the numbers are the real
// end-to-end cost of the taps — not a microbenchmark of isolated functions.
//
// Scenarios:
//   idle          The app must be near-invisible while hands are off.
//   touchstorm    Gesture events (type 29) at trackpad frame rate — the
//                 listen-only touch tap's hot path (scrolling, swiping).
//   dragstorm     leftMouseDragged at 120 Hz — the active click tap's
//                 pass-through path (any normal drag in any app).
//   scrollcontrol Scroll events, which match no tap mask — a negative
//                 control proving irrelevant HID traffic never wakes the app.
//   latency       Post→observe round-trip of drag events through the active
//                 tap, sampled by a tail-appended listen-only tap.
//
// Posting events and installing the latency tap require the one-time
// Accessibility grant for the terminal running this tool; `idle` needs
// nothing. Scenarios that lack their permission are skipped with a note.

// MARK: - rusage sampling

var timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

func machToSeconds(_ t: UInt64) -> Double {
    Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

struct Sample {
    let wall: Double // seconds, monotonic
    let cpu: Double // user+system seconds
    let idleWakeups: UInt64
    let interruptWakeups: UInt64
    let energyNJ: UInt64
    let footprint: UInt64

    static func take(pid: pid_t) -> Sample? {
        var info = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard rc == 0 else { return nil }
        return Sample(
            wall: machToSeconds(mach_continuous_time()),
            cpu: machToSeconds(info.ri_user_time) + machToSeconds(info.ri_system_time),
            idleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups,
            energyNJ: info.ri_billed_energy,
            footprint: info.ri_phys_footprint
        )
    }
}

/// Samples `pid`, printing a failure note and bumping `failures` on nil.
func sampleOrFail(pid: pid_t, message: String = "") -> Sample? {
    guard let s = Sample.take(pid: pid) else {
        print("    rusage failed" + (message.isEmpty ? "" : " — \(message)"))
        failures += 1
        return nil
    }
    return s
}

struct Delta {
    let seconds: Double
    let cpuPercent: Double
    let wakeupsPerSec: Double
    let powerMicroW: Double
    let footprintMB: Double

    init(from a: Sample, to b: Sample) {
        seconds = b.wall - a.wall
        cpuPercent = (b.cpu - a.cpu) / seconds * 100
        wakeupsPerSec = Double(
            (b.idleWakeups - a.idleWakeups) + (b.interruptWakeups - a.interruptWakeups)
        ) / seconds
        powerMicroW = Double(b.energyNJ - a.energyNJ) / seconds / 1000
        footprintMB = Double(b.footprint) / 1_048_576
    }

    func describe() -> String {
        String(
            format: "%6.1fs  cpu %6.3f%%  wakeups %5.1f/s  power %7.1f µW  mem %5.1f MB",
            seconds, cpuPercent, wakeupsPerSec, powerMicroW, footprintMB
        )
    }
}

/// Seconds since the user last touched any input device. The app's cost
/// while the user types or scrolls is a different (much higher) number than
/// its idle cost, so idle buckets contaminated by input must be discarded.
func secondsSinceLastUserInput() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return .infinity }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(
        service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue() as? UInt64 else { return .infinity }
    return Double(value) / 1e9
}

// MARK: - Finding the app

func findWheelClick() -> pid_t? {
    let expected = "/WheelClick.app/Contents/MacOS/WheelClick"
    var pids = [pid_t](repeating: 0, count: 4096)
    let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return nil }
    var path = [CChar](repeating: 0, count: 4 * 1024)
    for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
        path[0] = 0
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
        if String(cString: path).hasSuffix(expected) { return pid }
    }
    return nil
}

// MARK: - Synthetic event posting

/// NSEvent.EventType.gesture as delivered to taps; mirrors TapController.
let gestureEventType = CGEventType(rawValue: 29)!

func makeGestureEvent() -> CGEvent? {
    guard let event = CGEvent(source: nil) else { return nil }
    event.type = gestureEventType
    return event
}

func makeDragEvent() -> CGEvent? {
    // Zero-delta drag at the current cursor position: matches the active tap
    // mask, moves nothing, and with no button actually down every app's
    // mouseDragged tracking ignores it.
    guard let location = CGEvent(source: nil)?.location else { return nil }
    return CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDragged,
        mouseCursorPosition: location, mouseButton: .left
    )
}

func makeScrollEvent() -> CGEvent? {
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)
}

/// Posts `hz * seconds` events on a fixed cadence and returns the count.
func storm(seconds: Double, hz: Double, make: () -> CGEvent?) -> Int {
    let interval = 1.0 / hz
    let count = Int(seconds * hz)
    let start = DispatchTime.now()
    for i in 0..<count {
        make()?.post(tap: .cgSessionEventTap)
        let deadline = start + interval * Double(i + 1)
        let now = DispatchTime.now()
        if deadline > now {
            usleep(UInt32((deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1000))
        }
    }
    return count
}

// MARK: - Scenario runner

struct Budget {
    var cpuPercent: Double?
    var wakeupsPerSec: Double?
    var cpuMicrosPerEvent: Double?
}

var failures = 0

func check(_ name: String, _ value: Double, notAbove limit: Double, unit: String) {
    let ok = value <= limit
    if !ok { failures += 1 }
    print(String(format: "    %@ %@: %.3f %@ (budget %.3f)", ok ? "PASS" : "FAIL", name, value, unit, limit))
}

func measure(
    _ title: String, pid: pid_t, budget: Budget = Budget(),
    events: (() -> Int)? = nil, idleSeconds: Double = 0
) {
    print("\n== \(title)")
    guard let before = sampleOrFail(pid: pid, message: "is the app still running?") else { return }
    var posted = 0
    if let events {
        posted = events()
    } else {
        Thread.sleep(forTimeInterval: idleSeconds)
    }
    guard let after = sampleOrFail(pid: pid, message: "app died mid-scenario") else { return }
    let delta = Delta(from: before, to: after)
    print("    \(delta.describe())")
    if posted > 0 {
        let microsPerEvent = (after.cpu - before.cpu) / Double(posted) * 1e6
        print(String(format: "    %d events -> %.1f µs CPU per event", posted, microsPerEvent))
        if let limit = budget.cpuMicrosPerEvent {
            check("CPU/event", microsPerEvent, notAbove: limit, unit: "µs")
        }
    }
    if let limit = budget.cpuPercent { check("CPU", delta.cpuPercent, notAbove: limit, unit: "%") }
    if let limit = budget.wakeupsPerSec { check("wakeups", delta.wakeupsPerSec, notAbove: limit, unit: "/s") }
}

/// Idle measured in buckets. Buckets during which the user touched any input
/// device are discarded (input drives the taps, which is a different cost),
/// and the quietest clean bucket is the idle floor.
func measureIdle(pid: pid_t, seconds: Double, buckets: Int, budget: Budget) {
    print("\n== idle \(Int(seconds))s (\(buckets) buckets — keep hands off for at least one bucket)")
    var samples: [Sample] = []
    var handsOff: [Bool] = []
    guard let first = sampleOrFail(pid: pid, message: "is the app running?") else { return }
    samples.append(first)
    let bucketSeconds = seconds / Double(buckets)
    for _ in 0..<buckets {
        // Poll input idleness once a second; one touch taints the bucket.
        var untouched = true
        for _ in 0..<Int(bucketSeconds) {
            Thread.sleep(forTimeInterval: 1)
            if secondsSinceLastUserInput() < 1 { untouched = false }
        }
        guard let s = sampleOrFail(pid: pid, message: "app died mid-scenario") else { return }
        samples.append(s)
        handsOff.append(untouched)
    }
    var best: Delta?
    for i in 1..<samples.count {
        let d = Delta(from: samples[i - 1], to: samples[i])
        print("    bucket \(i): \(d.describe())\(handsOff[i - 1] ? "" : "  [user input — discarded]")")
        if handsOff[i - 1], best == nil || d.cpuPercent < best!.cpuPercent { best = d }
    }
    let overall = Delta(from: samples.first!, to: samples.last!)
    print("    overall : \(overall.describe())")
    guard let best else {
        print("    FAIL: no hands-off bucket — rerun while leaving the machine alone")
        failures += 1
        return
    }
    print("    idle floor (quietest hands-off bucket):")
    if let limit = budget.cpuPercent { check("CPU", best.cpuPercent, notAbove: limit, unit: "%") }
    if let limit = budget.wakeupsPerSec { check("wakeups", best.wakeupsPerSec, notAbove: limit, unit: "/s") }
}

// MARK: - Latency scenario

/// Collects post→observe intervals; a global so the C tap callback can
/// reach it without pointer gymnastics.
final class LatencyRecorder {
    static let shared = LatencyRecorder()
    var postTime: Double = 0
    var received: [Double] = []
}

/// Posts drag events and observes them again through a listen-only tap
/// appended at the session tail — after WheelClick's head-inserted active
/// tap — so the interval includes the full trip through the app.
func measureLatency(sampleCount: Int, hz: Double) {
    print("\n== latency (post -> tail tap, through the active click tap)")
    let mask = CGEventMask(1) << CGEventType.leftMouseDragged.rawValue
    guard let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, _, event, _ in
            let recorder = LatencyRecorder.shared
            recorder.received.append(machToSeconds(mach_continuous_time()) - recorder.postTime)
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) else {
        print("    skipped: cannot install listen tap (no Accessibility grant for this terminal)")
        return
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    CGEvent.tapEnable(tap: port, enable: true)

    for _ in 0..<sampleCount {
        LatencyRecorder.shared.postTime = machToSeconds(mach_continuous_time())
        makeDragEvent()?.post(tap: .cgSessionEventTap)
        // Spin the run loop until the event comes back (or 50 ms passes).
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
        usleep(UInt32(1_000_000 / hz))
    }
    CGEvent.tapEnable(tap: port, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
    CFMachPortInvalidate(port)

    let received = LatencyRecorder.shared.received
    guard received.count > sampleCount / 2 else {
        print("    skipped: only \(received.count)/\(sampleCount) events observed — likely missing the post grant")
        return
    }
    let sorted = received.sorted()
    func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
    print(String(
        format: "    %d samples  p50 %.3f ms  p95 %.3f ms  p99 %.3f ms  max %.3f ms",
        sorted.count, pct(0.5), pct(0.95), pct(0.99), sorted.last! * 1000
    ))
    check("p95 latency", pct(0.95), notAbove: 2.0, unit: "ms")
}

// MARK: - Shared accessory app / synthetic mouse event helpers

/// Activates this tool as an accessory app so it can own windows and pump
/// its own event loop, as `measureRemap` and `measureAutoscroll` both need.
func accessoryApp() -> NSApplication {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    return app
}

/// A borderless topmost square window, centered on screen, that catches
/// synthetic mouse/scroll events so nothing else on screen reacts to them.
func topmostWindow(size: CGFloat) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: size, height: size),
        styleMask: .borderless, backing: .buffered, defer: false
    )
    window.level = .screenSaver
    window.center()
    window.orderFrontRegardless()
    return window
}

func postMouseEvent(_ type: CGEventType, at position: CGPoint, fn: Bool) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: .left)
    else { return }
    if fn { event.flags = .maskSecondaryFn }
    event.post(tap: .cgSessionEventTap)
}

// MARK: - Remap scenario

/// Records which mouse buttons the content view actually saw.
final class RemapProbeView: NSView {
    var downs = 0, drags = 0, ups = 0, wrongButton = 0
    var fnFlagLeaked = false

    override func otherMouseDown(with event: NSEvent) {
        downs += 1
        if event.modifierFlags.contains(.function) { fnFlagLeaked = true }
    }
    override func otherMouseDragged(with event: NSEvent) { drags += 1 }
    override func otherMouseUp(with event: NSEvent) { ups += 1 }
    override func mouseDown(with event: NSEvent) { wrongButton += 1 }
    override func rightMouseDown(with event: NSEvent) { wrongButton += 1 }
}

/// End-to-end functional check: an fn+left press posted into the session
/// must come back out of WheelClick's taps as a middle press, drags and
/// release included. The click lands in this process's own topmost window,
/// so nothing else on screen can react to it.
func measureRemap() {
    print("\n== remap (fn+left press must arrive as a middle press)")
    let app = accessoryApp()

    let view = RemapProbeView()
    let window = topmostWindow(size: 220)
    window.contentView = view

    guard let originalPosition = CGEvent(source: nil)?.location else { return }
    // CG coordinates hang from the primary screen's top-left corner;
    // window frames grow from its bottom-left.
    let frame = window.frame
    let target = CGPoint(x: frame.midX, y: NSScreen.screens[0].frame.height - frame.midY)
    CGWarpMouseCursorPosition(target)

    func pump(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            guard let event = app.nextEvent(matching: .any, until: end, inMode: .default, dequeue: true)
            else { continue }
            app.sendEvent(event)
        }
    }

    pump(0.3)
    postMouseEvent(.leftMouseDown, at: target, fn: true)
    pump(0.1)
    for _ in 0..<5 {
        postMouseEvent(.leftMouseDragged, at: target, fn: true)
        pump(0.03)
    }
    postMouseEvent(.leftMouseUp, at: target, fn: true)
    pump(0.4)

    CGWarpMouseCursorPosition(originalPosition)
    window.orderOut(nil)

    print("    middle events: \(view.downs) down, \(view.drags) dragged, \(view.ups) up; wrong-button: \(view.wrongButton)\(view.fnFlagLeaked ? "; fn flag leaked" : "")")
    let ok = view.downs == 1 && view.ups == 1 && view.drags >= 1
        && view.wrongButton == 0 && !view.fnFlagLeaked
    if !ok { failures += 1 }
    print("    \(ok ? "PASS" : "FAIL") fn+left -> middle remap")
}

// MARK: - Autoscroll scenario

/// Counts the scroll the app emits during a session; a global so the C tap
/// callback can reach it without pointer gymnastics (like LatencyRecorder).
final class ScrollCounter {
    static let shared = ScrollCounter()
    var count = 0
}

/// Draw while an autoscroll session is actively scrolling. Autoscroll isn't
/// driven by incoming events like the storms — it's a self-spun ~60 Hz timer
/// the app runs ONLY while a session is live, and nothing at rest. So this
/// enters a session with the configured trigger (fn+click), parks the cursor
/// far below the anchor so the timer posts a scroll every frame, samples for
/// `seconds`, then clicks to exit. Headline: power (mW) while active. A tail
/// tap counts the emitted scroll, so a session that never started is caught,
/// not silently measured as ~0.
///
/// Assumes the app is set to enter autoscroll on fn+click
/// (plugin.autoScrollTrigger = fnClick, fnClick = true) — rate-features.sh
/// configures that first. A borderless topmost window under the parked cursor
/// swallows the synthetic scroll so nothing on screen actually moves.
func measureAutoscroll(pid: pid_t, seconds: Double) {
    print("\n== autoscroll (draw while a session actively scrolls)")
    _ = accessoryApp()
    guard let origin = CGEvent(source: nil)?.location else {
        print("    skipped: no cursor position"); failures += 1; return
    }

    // A borderless topmost window to catch the synthetic scroll harmlessly.
    let window = topmostWindow(size: 400)
    let frame = window.frame
    // CG coordinates hang from the primary screen's top-left; window frames grow
    // from its bottom-left. Anchor in the upper half, park 240 px below it (a
    // cursor below the anchor scrolls down), both inside the window.
    let flip = NSScreen.screens[0].frame.height
    let anchor = CGPoint(x: frame.midX, y: flip - (frame.midY + 120))
    let parked = CGPoint(x: frame.midX, y: flip - (frame.midY - 120))

    // Tail-appended listen tap: counts the app's emitted scroll to prove the
    // session is live.
    let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
    let tapPort = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, _, event, _ in
            ScrollCounter.shared.count += 1
            return Unmanaged.passUnretained(event)
        }, userInfo: nil
    )
    if let tapPort {
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
        CGEvent.tapEnable(tap: tapPort, enable: true)
    }

    // Enter: an fn+click at the anchor toggles scroll mode (app configured for it).
    CGWarpMouseCursorPosition(anchor)
    usleep(120_000)
    postMouseEvent(.leftMouseDown, at: anchor, fn: true)
    usleep(20_000)
    postMouseEvent(.leftMouseUp, at: anchor, fn: true)
    usleep(120_000)

    // Park below the anchor so the curve is wound up and the timer scrolls every
    // frame; let it reach steady state before the sampling window opens.
    CGWarpMouseCursorPosition(parked)
    usleep(200_000)

    guard let before = sampleOrFail(pid: pid) else { return }
    // Spin the run loop (not Thread.sleep) so the tail tap keeps counting scroll.
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    guard let after = sampleOrFail(pid: pid, message: "app died?") else { return }
    let delta = Delta(from: before, to: after)

    // Exit: a plain click (no fn) ends the session.
    postMouseEvent(.leftMouseDown, at: parked, fn: false)
    usleep(20_000)
    postMouseEvent(.leftMouseUp, at: parked, fn: false)
    usleep(50_000)
    if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: false) }
    CGWarpMouseCursorPosition(origin)
    window.orderOut(nil)

    let scrolls = ScrollCounter.shared.count
    print("    \(delta.describe())")
    guard scrolls > Int(seconds * 10) else {
        // Far below the ~60/s a live session emits: it never entered (config?).
        print("    skipped: only \(scrolls) scroll events seen — session didn't start (check plugin.autoScrollTrigger = fnClick, fnClick = true)")
        return
    }
    let milliwatts = delta.powerMicroW / 1000
    print(String(
        format: "    %.2f mW while scrolling  (cpu %.3f%%, %.1f wakeups/s, %d scrolls)",
        milliwatts, delta.cpuPercent, delta.wakeupsPerSec, scrolls
    ))
}

// MARK: - Main

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "all"
let stormSeconds = 15.0
let stormHz = 120.0

// Budgets. Idle numbers are hard requirements for an always-running app;
// per-event numbers assume a Release build on Apple Silicon. Drags at rest
// must not reach the app at all (the drag tap is off outside a remapped
// press), so dragstorm's budget is a rounding error, like the control's.
let idleBudget = Budget(cpuPercent: 0.05, wakeupsPerSec: 1.0)
let touchBudget = Budget(cpuMicrosPerEvent: 100)
let dragBudget = Budget(wakeupsPerSec: 2.0, cpuMicrosPerEvent: 5)
let controlBudget = Budget(cpuPercent: 0.05, wakeupsPerSec: 2.0)

if command == "request-permissions" {
    CGRequestPostEventAccess()
    CGRequestListenEventAccess()
    exit(0)
}

guard let pid = findWheelClick() else {
    print("WheelClick is not running — launch it first (perf/run.sh does).")
    exit(2)
}
print("Measuring WheelClick pid \(pid)")

let canPost = CGPreflightPostEventAccess()
if !canPost {
    print("""
    NOTE: this terminal has no synthetic-event grant, so only `idle` runs.
    To enable the storm/latency scenarios, run once:
        perf/run.sh request-permissions
    and allow the prompt (System Settings > Privacy & Security > Accessibility).
    """)
}

func runTouchstorm() {
    measure("touchstorm \(Int(stormHz)) Hz gesture events", pid: pid, budget: touchBudget) {
        storm(seconds: stormSeconds, hz: stormHz, make: makeGestureEvent)
    }
}
func runDragstorm() {
    measure("dragstorm \(Int(stormHz)) Hz drag events", pid: pid, budget: dragBudget) {
        storm(seconds: stormSeconds, hz: stormHz, make: makeDragEvent)
    }
}
func runScrollcontrol() {
    measure("scrollcontrol \(Int(stormHz)) Hz scroll events (must NOT wake the app)", pid: pid, budget: controlBudget) {
        storm(seconds: stormSeconds, hz: stormHz, make: makeScrollEvent)
    }
}

switch command {
case "idle":
    measureIdle(pid: pid, seconds: 60, buckets: 6, budget: idleBudget)
case "touchstorm" where canPost:
    runTouchstorm()
case "dragstorm" where canPost:
    runDragstorm()
case "scrollcontrol" where canPost:
    runScrollcontrol()
case "latency" where canPost:
    measureLatency(sampleCount: 200, hz: 60)
case "remap" where canPost:
    measureRemap()
case "autoscroll" where canPost:
    measureAutoscroll(pid: pid, seconds: 10)
case "all":
    measureIdle(pid: pid, seconds: 60, buckets: 6, budget: idleBudget)
    if canPost {
        runTouchstorm()
        runDragstorm()
        runScrollcontrol()
        measureLatency(sampleCount: 200, hz: 60)
        measureRemap()
    }
default:
    print("Unknown or permission-gated command: \(command)")
    exit(2)
}

print(failures == 0 ? "\nAll budgets met." : "\n\(failures) budget check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
