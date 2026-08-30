import Darwin
import Foundation

// Prints one machine-readable line per pid argument:
//   <pid> avg_mw=<lifetime average power> mj_per_cpu_s=<energy per CPU second>
// Used by rate-features.sh to capture reference points (the menu bar
// clock's draw, this machine's energy cost of a CPU second) alongside the
// feature measurements. Reads rusage only — needs no permissions.

var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
func sec(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9 }

for arg in CommandLine.arguments.dropFirst() {
    guard let pid = pid_t(arg) else { continue }
    var info = rusage_info_current()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
        }
    }
    guard rc == 0 else {
        print("\(arg) error")
        continue
    }
    let energyJ = Double(info.ri_billed_energy) / 1e9
    let cpuS: Double = sec(info.ri_user_time) + sec(info.ri_system_time)
    let uptimeS: Double = sec(mach_absolute_time() - info.ri_proc_start_abstime)
    let avgMW: Double = uptimeS > 0 ? energyJ / uptimeS * 1000 : 0
    let mjPerCpuS: Double = cpuS > 0 ? energyJ / cpuS * 1000 : 0
    print(String(format: "%@ avg_mw=%.4f mj_per_cpu_s=%.1f", arg, avgMW, mjPerCpuS))
}
