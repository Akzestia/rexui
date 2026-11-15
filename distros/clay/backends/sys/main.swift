// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import IOKit.ps

let rexui = RexuiBackend()

func cpuTicks() -> (busy: UInt64, total: UInt64) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard r == KERN_SUCCESS else { return (0, 0) }
    let user = UInt64(info.cpu_ticks.0)
    let system = UInt64(info.cpu_ticks.1)
    let idle = UInt64(info.cpu_ticks.2)
    let nice = UInt64(info.cpu_ticks.3)
    return (user + system + nice, user + system + idle + nice)
}

func memUsed() -> Double {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let r = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard r == KERN_SUCCESS else { return 0 }
    let page = Double(vm_kernel_page_size)
    let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
    return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
}

func disk() -> (used: Double, total: Double) {
    let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
    guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
        let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
    else { return (0, 0) }
    return (Double(total) - Double(free), Double(total))
}

func battery() -> (level: Double, charging: Bool) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return (-1, false) }
    for src in list {
        guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
            let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
        else { continue }
        return (Double(cap) / Double(max), (d[kIOPSIsChargingKey] as? Bool) ?? false)
    }
    return (-1, false)
}

let info = ProcessInfo.processInfo
let v = info.operatingSystemVersion
let os = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
let host = Host.current().localizedName ?? info.hostName
let user = NSUserName()

Thread.detachNewThread {
    while rexui.readLine() != nil {}
    exit(0)
}

var lastCpu = cpuTicks()
while true {
    Thread.sleep(forTimeInterval: 1)
    let cpu = cpuTicks()
    let busy = cpu.total > lastCpu.total ? Double(cpu.busy - lastCpu.busy) / Double(cpu.total - lastCpu.total) : 0
    lastCpu = cpu
    let memTotal = Double(info.physicalMemory)
    let used = memUsed()
    let d = disk()
    let b = battery()
    let state: [String: Any] = [
        "cpu": busy,
        "mem": memTotal > 0 ? used / memTotal : 0, "memUsed": used, "memTotal": memTotal,
        "disk": d.total > 0 ? d.used / d.total : 0, "diskUsed": d.used, "diskTotal": d.total,
        "battery": b.level, "charging": b.charging, "uptime": info.systemUptime,
        "user": user, "host": host, "os": os,
    ]
    rexui.emit(["state": state])
}
