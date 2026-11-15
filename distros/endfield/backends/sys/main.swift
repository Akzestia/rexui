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

func coreTicks() -> [(busy: UInt64, total: UInt64)] {
    var count: natural_t = 0
    var info: processor_info_array_t?
    var n: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &n) == KERN_SUCCESS, let info
    else { return [] }
    defer {
        vm_deallocate(
            mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(n) * MemoryLayout<integer_t>.stride))
    }
    var out: [(UInt64, UInt64)] = []
    for i in 0..<Int(count) {
        let b = Int(CPU_STATE_MAX) * i
        let user = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]))
        let sys = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
        let idle = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
        let nice = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        out.append((user + sys + nice, user + sys + idle + nice))
    }
    return out
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

func netBytes() -> (UInt64, UInt64) {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
    var inB: UInt64 = 0
    var outB: UInt64 = 0
    var at = 0
    buf.withUnsafeBytes { raw in
        while at + MemoryLayout<if_msghdr>.size <= len {
            let h = raw.load(fromByteOffset: at, as: if_msghdr.self)
            if Int32(h.ifm_type) == RTM_IFINFO2 {
                let m = raw.load(fromByteOffset: at, as: if_msghdr2.self)
                if (Int32(m.ifm_flags) & IFF_LOOPBACK) == 0 {
                    inB &+= m.ifm_data.ifi_ibytes
                    outB &+= m.ifm_data.ifi_obytes
                }
            }
            at += Int(h.ifm_msglen)
            if h.ifm_msglen == 0 { break }
        }
    }
    return (inB, outB)
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let uid = getuid()
func procTimes() -> [Int32: (name: String, ns: UInt64)] {
    var pids = [Int32](repeating: 0, count: 4096)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    var out: [Int32: (String, UInt64)] = [:]
    guard n > 0 else { return out }
    for pid in pids.prefix(Int(n)) where pid > 0 {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size, info.pbsd.pbi_uid == uid else { continue }
        let ticks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
        let ns = ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
        var name = withUnsafeBytes(of: info.pbsd.pbi_name) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        if name.isEmpty {
            name = withUnsafeBytes(of: info.pbsd.pbi_comm) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
        }
        out[pid] = (name, ns)
    }
    return out
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

func thermal() -> String {
    switch info.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "nominal"
    }
}

var lastCpu = cpuTicks()
var lastCores = coreTicks()
var lastNet = netBytes()
var lastProcs = procTimes()
var lastProcsAt = Date()
var top: [[String: Any]] = []
var tick = 0
while true {
    Thread.sleep(forTimeInterval: 1)
    tick += 1
    let cpu = cpuTicks()
    let busy = cpu.total > lastCpu.total ? Double(cpu.busy - lastCpu.busy) / Double(cpu.total - lastCpu.total) : 0
    lastCpu = cpu
    let cores = coreTicks()
    var coreLoads: [Double] = []
    for (i, c) in cores.enumerated() where i < lastCores.count {
        let p = lastCores[i]
        coreLoads.append(c.total > p.total ? min(1, Double(c.busy &- p.busy) / Double(c.total - p.total)) : 0)
    }
    lastCores = cores
    let net = netBytes()
    let netIn = net.0 >= lastNet.0 ? Double(net.0 - lastNet.0) : 0
    let netOut = net.1 >= lastNet.1 ? Double(net.1 - lastNet.1) : 0
    lastNet = net
    if tick % 2 == 0 {
        let now = Date()
        let procs = procTimes()
        let wall = max(0.001, now.timeIntervalSince(lastProcsAt)) * 1e9
        var shares: [(String, Double)] = []
        for (pid, p) in procs {
            guard let was = lastProcs[pid], p.ns >= was.ns else { continue }
            let share = Double(p.ns - was.ns) / wall
            if share > 0.001 { shares.append((p.name, share)) }
        }
        top = shares.sorted { $0.1 > $1.1 }.prefix(4).map { ["name": $0.0, "cpu": ($0.1 * 1000).rounded() / 1000] }
        lastProcs = procs
        lastProcsAt = now
    }
    let memTotal = Double(info.physicalMemory)
    let used = memUsed()
    let d = disk()
    let b = battery()
    let state: [String: Any] = [
        "cpu": busy, "cores": coreLoads.map { ($0 * 1000).rounded() / 1000 },
        "mem": memTotal > 0 ? used / memTotal : 0, "memUsed": used, "memTotal": memTotal,
        "disk": d.total > 0 ? d.used / d.total : 0, "diskUsed": d.used, "diskTotal": d.total,
        "netIn": netIn, "netOut": netOut, "thermal": thermal(), "top": top,
        "battery": b.level, "charging": b.charging, "uptime": info.systemUptime,
        "user": user, "host": host, "os": os,
    ]
    rexui.emit(["state": state])
}
