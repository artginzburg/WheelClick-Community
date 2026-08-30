import Darwin
import Foundation

// RusageSample — one process's CPU, wakeups and billed energy, printed for a
// shell script to difference.
//
// Split out from EnergyBench because the Magic Mouse path is the first feature
// whose cost is spread across two processes: the app and its unsandboxed touch
// helper. Measuring only the app would flatter the feature by exactly the part
// that does the work.
//
//   rusage-sample <pid|name>   ->  cpu_seconds wakeups energy_nanojoules
//
// A name resolves to the newest matching process, or exits 1 if none is
// running -- which is itself a measurement: the helper is supposed to be
// absent while no Magic Mouse gesture is on.

func pid(named name: String) -> pid_t? {
    var count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return nil }
    var newest: pid_t?
    for candidate in pids.prefix(Int(count)) where candidate > 0 {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXPATHLEN))
        guard proc_pidpath(candidate, &buffer, UInt32(buffer.count)) > 0 else { continue }
        let path = String(cString: buffer)
        if path.contains(name) { newest = candidate }
    }
    return newest
}

func sample(_ target: pid_t) -> (cpu: Double, wakeups: UInt64, energy: UInt64)? {
    var info = rusage_info_current()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(target, RUSAGE_INFO_CURRENT, $0)
        }
    }
    guard result == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let seconds = { (ticks: UInt64) in
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
    return (
        seconds(info.ri_user_time) + seconds(info.ri_system_time),
        info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
        info.ri_billed_energy
    )
}

let arguments = CommandLine.arguments.dropFirst()
guard let argument = arguments.first else {
    FileHandle.standardError.write(Data("usage: rusage-sample <pid|name>\n".utf8))
    exit(2)
}

let target = pid_t(argument) ?? pid(named: argument) ?? -1
guard target > 0, let reading = sample(target) else {
    FileHandle.standardError.write(Data("no such process: \(argument)\n".utf8))
    exit(1)
}
print("\(reading.cpu) \(reading.wakeups) \(reading.energy)")
