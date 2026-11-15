// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import IOKit.ps

let rexui = RexuiBackend(features: ["patch", "credit"])

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

func netBytes() -> (rx: UInt64, tx: UInt64) {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
    defer { freeifaddrs(head) }
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let a = p.pointee
        guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data,
            (a.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
        else { continue }
        let d = data.assumingMemoryBound(to: if_data.self).pointee
        rx += UInt64(d.ifi_ibytes)
        tx += UInt64(d.ifi_obytes)
    }
    return (rx, tx)
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
let host = (Host.current().localizedName ?? info.hostName)

Thread.detachNewThread { rexui.run() }

var lastCpu = cpuTicks()
var lastNet = netBytes()
var lastTime = Date()
while true {
    Thread.sleep(forTimeInterval: 1)
    let cpu = cpuTicks()
    let net = netBytes()
    let now = Date()
    let dt = max(0.001, now.timeIntervalSince(lastTime))
    let busy = cpu.total > lastCpu.total ? Double(cpu.busy - lastCpu.busy) / Double(cpu.total - lastCpu.total) : 0
    let rx = net.rx >= lastNet.rx ? Double(net.rx - lastNet.rx) / dt : 0
    let tx = net.tx >= lastNet.tx ? Double(net.tx - lastNet.tx) / dt : 0
    lastCpu = cpu
    lastNet = net
    lastTime = now
    let memTotal = Double(info.physicalMemory)
    let used = memUsed()
    let d = disk()
    let b = battery()
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    let state: [String: Any?] = [
        "cpu": busy, "cores": info.activeProcessorCount,
        "memUsed": used, "memTotal": memTotal, "mem": memTotal > 0 ? used / memTotal : 0,
        "diskUsed": d.used, "diskTotal": d.total, "disk": d.total > 0 ? d.used / d.total : 0,
        "netIn": rx, "netOut": tx, "battery": b.level, "charging": b.charging,
        "uptime": info.systemUptime, "load": load[0],
        "user": NSUserName(), "host": host, "os": os,
    ]
    rexui.state(state)
}
