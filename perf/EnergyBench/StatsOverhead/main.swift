import Darwin
import Foundation

// Measures what UsageStats bookkeeping costs, for the About window's
// honesty line. Compiled by perf/rate-features.sh together with the app's
// own UsageStats.swift (unmodified), so the numbers are the production
// code path. Prints one machine-readable line:
//   ns_per_record=<X> us_per_flush=<Y>

var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
func nowNS() -> Double { Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) }

let stats = UsageStats()

// The per-click bookkeeping: dict bump, Date, throttle check.
let recordRuns = 1_000_000
var t0 = nowNS()
for _ in 0..<recordRuns { stats.recordOtherClick() }
let nsPerRecord = (nowNS() - t0) / Double(recordRuns)

// A full ledger encode plus UserDefaults write.
let flushRuns = 2_000
t0 = nowNS()
for _ in 0..<flushRuns { stats.flush() }
let usPerFlush = (nowNS() - t0) / 1000 / Double(flushRuns)

print(String(format: "ns_per_record=%.0f us_per_flush=%.1f", nsPerRecord, usPerFlush))
