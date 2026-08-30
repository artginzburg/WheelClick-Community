import AppKit
import ApplicationServices
import Darwin

// Measures what the per-app filter's gate costs on a candidate remap — the
// only place AppScope adds work. Compiled by perf/rate-features.sh together
// with the app's own AppScope/AppIdentity/AppInventory (unmodified), so the
// numbers are the production code path. Prints one machine-readable line:
//   ax_trusted=<yes|no> ns_all=<X> ns_frontmost=<Y> us_undercursor=<Z>
//
// `all` is today's default (the gate returns before any work); `frontmost`
// is the energy-efficient list mode (one cached-Bool read); `undercursor`
// is the opt-in method (one Accessibility hit-test per remap) — the
// undercursor figure is only real when ax_trusted=yes.

// The under-cursor figure is a real Accessibility hit-test only when this
// binary is AX-trusted. Run once with `request-permissions` to raise the
// system prompt, then enable this binary in System Settings > Accessibility.
if CommandLine.arguments.contains("request-permissions") {
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(prompt)
    print("Requested Accessibility — enable this binary in System Settings, then rerun.")
    exit(0)
}

var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
func nowNS() -> Double { Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) }

let scope = AppScope()
var sink = 0

func timePermits(_ n: Int) -> Double {
    let t0 = nowNS()
    for _ in 0..<n where scope.permitsActiveApp() { sink += 1 }
    return nowNS() - t0
}

// All-apps mode (the default): the gate short-circuits before touching state.
scope.mode = .all
let allRuns = 2_000_000
let nsAll = timePermits(allRuns) / Double(allRuns)

// A list mode with the default frontmost method: one cached-Bool read.
scope.detection = .frontmost
scope.mode = .ignore
let frontRuns = 2_000_000
let nsFrontmost = timePermits(frontRuns) / Double(frontRuns)

// The opt-in under-cursor method: one Accessibility hit-test per remap.
scope.detection = .underCursor
let cursorRuns = 2_000
let usCursor = timePermits(cursorRuns) / 1000 / Double(cursorRuns)

let trusted = AXIsProcessTrusted() ? "yes" : "no"
print(String(
    format: "ax_trusted=%@ ns_all=%.1f ns_frontmost=%.1f us_undercursor=%.1f sink=%d",
    trusted, nsAll, nsFrontmost, usCursor, sink
))
