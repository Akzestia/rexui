import AVFoundation
// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: GPL-3.0-only
import Accelerate
import AppKit
import CoreAudio
import Foundation

let rexui = RexuiBackend()

func log(_ s: String) { FileHandle.standardError.write(("rexui-visualiser: " + s + "\n").data(using: .utf8)!) }

func hann(_ n: Int) -> [Double] {
    var w = [Double](repeating: 0, count: n)
    for i in 0..<n { w[i] = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n - 1))) }
    return w
}

final class Cava {
    let bars: Int
    let rate: Double
    let noiseReduction: Double
    let fftSize: Int, bassSize: Int
    var input: [Double]
    var lower: [Int], upper: [Int], eq: [Double]
    var bassBars = 0
    var fall: [Double], mem: [Double], peak: [Double], prev: [Double]
    var sens = 1.0, sensInit = true
    var framerate = 75.0, frameSkip = 1.0
    let bassWindow: [Double], window: [Double]
    let bassSetup: FFTSetupD, setup: FFTSetupD
    var treble: [Double] = []

    init(bars: Int, rate: Int, sizedFor: Int? = nil, noiseReduction: Double = 0.85, low: Int = 50, high: Int = 10000) {
        self.bars = bars
        self.rate = Double(rate)
        self.noiseReduction = noiseReduction
        let sizing = sizedFor ?? rate
        var size = 512
        if sizing > 8125 && sizing <= 16250 {
            size *= 2
        } else if sizing > 16250 && sizing <= 32500 {
            size *= 4
        } else if sizing > 32500 && sizing <= 75000 {
            size *= 8
        } else if sizing > 75000 && sizing <= 150000 {
            size *= 16
        } else if sizing > 150000 && sizing <= 300000 {
            size *= 32
        } else if sizing > 300000 {
            size *= 64
        }
        fftSize = size
        bassSize = size * 2
        input = [Double](repeating: 0, count: bassSize)
        lower = [Int](repeating: 0, count: bars + 1)
        upper = [Int](repeating: 0, count: bars + 1)
        eq = [Double](repeating: 0, count: bars + 1)
        fall = [Double](repeating: 0, count: bars)
        mem = fall
        peak = fall
        prev = fall
        bassWindow = hann(size * 2)
        window = hann(size)
        bassSetup = vDSP_create_fftsetupD(vDSP_Length(log2(Double(bassSize))), FFTRadix(kFFTRadix2))!
        setup = vDSP_create_fftsetupD(vDSP_Length(log2(Double(size))), FFTRadix(kFFTRadix2))!

        let bassCutOff = 100.0
        let fc = log10(Double(low) / Double(high)) / (1 / (Double(bars) + 1) - 1)
        var cut = [Double](repeating: 0, count: bars + 1)
        var firstBar = true
        let minBandwidth = Double(rate / bassSize)
        for n in 0...bars {
            var coeff = -fc
            coeff += (Double(n) + 1) / (Double(bars) + 1) * fc
            cut[n] = Double(Float(Double(high) * pow(10, coeff)))
            if n > 0 && cut[n - 1] >= cut[n] { cut[n] = cut[n - 1] + minBandwidth }
            var relative = Float(cut[n] / (self.rate / 2))
            if cut[n] < bassCutOff {
                lower[n] = Int(relative * Float(bassSize / 2))
                bassBars += 1
                if bassBars > 1 { firstBar = false }
                if lower[n] > bassSize / 2 { lower[n] = bassSize / 2 }
            } else {
                lower[n] = Int(ceil(relative * Float(size / 2)))
                if n == bassBars {
                    firstBar = true
                    if n > 0 { upper[n - 1] = Int(relative * Float(bassSize / 2)) - 1 }
                } else {
                    firstBar = false
                }
                if lower[n] > size / 2 { lower[n] = size / 2 }
            }
            if n > 0 {
                if !firstBar {
                    upper[n - 1] = lower[n] - 1
                    if lower[n] <= lower[n - 1] {
                        let room = n < bassBars ? lower[n - 1] + 1 < bassSize / 2 + 1 : lower[n - 1] + 1 < size / 2 + 1
                        if room {
                            lower[n] = lower[n - 1] + 1
                            upper[n - 1] = lower[n] - 1
                        }
                    }
                } else if upper[n - 1] < lower[n - 1] {
                    upper[n - 1] = lower[n - 1] + 1
                }
            }
            relative = n < bassBars ? Float(lower[n]) / Float(bassSize / 2) : Float(lower[n]) / Float(size / 2)
            cut[n] = Double(relative) * (self.rate / 2)
        }
        for n in 0..<bars {
            eq[n] = 1 / pow(2, 28)
            eq[n] *= pow(cut[n + 1], 0.85)
            eq[n] /= log2(Double(n < bassBars ? bassSize : size))
            eq[n] /= Double(upper[n] - lower[n] + 1)
        }
    }

    func spectrum(_ n: Int, _ w: [Double], _ setup: FFTSetupD) -> [Double] {
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[i] = input[i] * w[i] }
        var re = [Double](repeating: 0, count: n / 2)
        var im = re
        var mags = [Double](repeating: 0, count: n / 2 + 1)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: n / 2) {
                        vDSP_ctozD($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
                mags[0] = abs(rp[0]) / 2
                mags[n / 2] = abs(ip[0]) / 2
                for k in 1..<(n / 2) { mags[k] = hypot(rp[k], ip[k]) / 2 }
            }
        }
        return mags
    }

    func execute(_ samples: ArraySlice<Float>) -> [Double] {
        var silence = true
        let count = min(samples.count, input.count)
        if count > 0 {
            framerate -= framerate / 64
            framerate += rate * frameSkip / Double(count) / 64
            frameSkip = 1
            input.replaceSubrange(count..<input.count, with: input[0..<(input.count - count)])
            var i = count - 1
            for s in samples.suffix(count) {
                input[i] = Double(s)
                if s != 0 { silence = false }
                i -= 1
            }
        } else {
            frameSkip += 1
        }
        let bass = spectrum(bassSize, bassWindow, bassSetup)
        treble = spectrum(fftSize, window, setup)
        var out = [Double](repeating: 0, count: bars)
        for n in 0..<bars {
            var t = 0.0
            if upper[n] >= lower[n] {
                for i in lower[n]...upper[n] { t += n < bassBars ? bass[i] : treble[i] }
            }
            out[n] = t * eq[n] * sens
        }
        var overshoot = false
        let framerateMod = 66 / framerate
        let gravityMod = pow(framerateMod, 2.5) * 2 / noiseReduction
        let integralMod = pow(framerateMod, 0.1)
        for n in 0..<bars {
            if out[n] < prev[n] && noiseReduction > 0.1 {
                out[n] = max(0, peak[n] * (1 - fall[n] * fall[n] * gravityMod))
                fall[n] += 0.028
            } else {
                peak[n] = out[n]
                fall[n] = 0
            }
            prev[n] = out[n]
            out[n] = mem[n] * noiseReduction / integralMod + out[n]
            mem[n] = out[n]
            if out[n] > 1 {
                overshoot = true
                out[n] = 1
            }
        }
        if overshoot {
            sens *= 1 - 0.02 * framerateMod
            sensInit = false
        } else if !silence {
            sens *= 1 + 0.001 * framerateMod
            if sensInit { sens *= 1 + 0.1 * framerateMod }
        }
        return out
    }
}

func monstercat(_ v: [Double]) -> [Double] {
    var out = v
    var carry = 0.0
    for i in 0..<v.count {
        carry = max(v[i], carry / 1.5)
        out[i] = carry
    }
    carry = 0
    for i in stride(from: v.count - 1, through: 0, by: -1) {
        carry = max(v[i], carry / 1.5)
        out[i] = max(out[i], carry)
    }
    return out
}

final class Beat {
    let fps: Double
    var last: [Double] = []
    var flux: [Double] = []
    var frames = 0
    var found: [Double] = []
    var bpm = 0.0

    init(fps: Double) { self.fps = fps }

    func add(_ spectrum: [Double]) {
        let mags = spectrum.map { log1p(100 * $0) }
        var f = 0.0
        if last.count == mags.count { for i in 0..<mags.count { f += max(0, mags[i] - last[i]) } }
        last = mags
        flux.append(f)
        if flux.count > Int(fps * 8) { flux.removeFirst(flux.count - Int(fps * 8)) }
        frames += 1
        if frames % Int(fps) == 0 && flux.count >= Int(fps * 6) { estimate() }
    }

    func estimate() {
        let mean = flux.reduce(0, +) / Double(flux.count)
        let x = flux.map { $0 - mean }
        let energy = x.reduce(0) { $0 + $1 * $1 }
        if energy < 1e-9 { return }
        let lo = Int(floor(60 * fps / 200))
        let hi = Int(ceil(60 * fps / 60))
        var r = [Double](repeating: 0, count: min(x.count, 4 * (hi + 1) + 1))
        for lag in 0..<r.count {
            var sum = 0.0
            for i in lag..<x.count { sum += x[i] * x[i - lag] }
            r[lag] = sum / energy
        }
        var score = [Double](repeating: 0, count: hi + 2)
        for lag in lo...(hi + 1) {
            var comb = 0.0
            for k in 1...4 where k * lag < r.count { comb += r[k * lag] / Double(k) }
            let b = 60 * fps / Double(lag)
            score[lag] = comb * exp(-pow(log2(b / 120), 2) / 2)
        }
        var best = lo
        for lag in lo...hi where score[lag] > score[best] { best = lag }
        if score[best] <= 0 { return }
        let a = score[max(lo, best - 1)]
        let b = score[best]
        let c = score[best + 1]
        let d = a - 2 * b + c
        let lag = Double(best) + (d != 0 ? 0.5 * (a - c) / d : 0)
        found.append(60 * fps / lag)
        if found.count > 5 { found.removeFirst() }
        bpm = found.sorted()[found.count / 2]
    }
}

var atRest = false
var beat: Beat?
var json = false
var frames = rexui_frames_writer()
var lastBpm = -1
var lift = 0.7
func emit(_ values: [Double]) {
    let v = monstercat(values).map { pow(min(1, max(0, $0)), lift) }
    let bpm = Int((beat?.bpm ?? 0).rounded())
    if bpm != lastBpm {
        lastBpm = bpm
        rexui.state(["bpm": bpm])
    }
    let rest = v.allSatisfy { $0 < 0.005 }
    if rest && atRest && !fast { return }
    atRest = rest
    if frames.f != nil {
        let back = rexui_frames_back(&frames)!
        for i in 0..<v.count { back[i] = Float(v[i]) }
        rexui_frames_publish(&frames, UInt32(v.count))
    }
    if json { rexui.state(["bars": v.map { ($0 * 1000).rounded() / 1000 }]) }
}

var args = Array(CommandLine.arguments.dropFirst())
var file: String?
if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
    file = (args[i + 1] as NSString).expandingTildeInPath
    args.removeSubrange(i...(i + 1))
}
if let i = args.firstIndex(of: "--json") {
    json = true
    args.remove(at: i)
}
var exact = false
if let i = args.firstIndex(of: "--cava") {
    exact = true
    lift = 1
    args.remove(at: i)
}
var fast = false
if let i = args.firstIndex(of: "--fast") {
    fast = true
    args.remove(at: i)
}
func makeCava(_ rate: Int) -> Cava {
    exact ? Cava(bars: barCount, rate: rate) : Cava(bars: barCount, rate: rate, sizedFor: rate / 4, noiseReduction: 0.7)
}
let barCount = max(1, min(200, Int(args.first ?? "") ?? 60))

let sensFile = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/rexui/visualiser-sensitivity"
func loadSens(_ cava: Cava) {
    if let s = try? String(contentsOfFile: sensFile, encoding: .utf8),
        let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
        v.isFinite, v > 0
    {
        cava.sens = v
        cava.sensInit = false
    }
}
var saveCava: Cava?
func saveSens() {
    guard let cava = saveCava, !cava.sensInit else { return }
    try? FileManager.default.createDirectory(
        atPath: (sensFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? String(cava.sens).write(toFile: sensFile, atomically: true, encoding: .utf8)
}

let framesName = "/rexui.\(getpid()).bars"
if rexui_frames_create(&frames, framesName, UInt32(barCount)) == 0 {
    rexui.state(["frames": framesName])
} else {
    log("no shared memory for the frames (errno \(errno)); only --json works")
}
atexit {
    rexui_frames_close(&frames)
    saveSens()
}
signal(SIGTERM, SIG_IGN)
let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
terminated.setEventHandler { exit(0) }
terminated.resume()

func watchStdin(_ line: @escaping ([String: Any]) -> Void = { _ in }, _ cleanup: @escaping () -> Void) {
    Thread.detachNewThread {
        while let l = rexui.readLine() {
            guard let m = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { continue }
            DispatchQueue.main.async { line(m) }
        }
        cleanup()
        exit(0)
    }
}

if let file {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: file))
    let rate = Int(f.processingFormat.sampleRate)
    let cava = makeCava(rate)
    if !fast {
        loadSens(cava)
        saveCava = cava
    }
    let hop = 256
    beat = Beat(fps: Double(rate) / Double(hop))
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(hop))!
    let start = Date()
    var frames = 0
    while (try? f.read(into: buf, frameCount: AVAudioFrameCount(hop))) != nil, buf.frameLength > 0 {
        let chans = Int(buf.format.channelCount)
        let n = Int(buf.frameLength)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chans { for i in 0..<n { mono[i] += buf.floatChannelData![c][i] / Float(chans) } }
        let bars = cava.execute(mono[...])
        beat?.add(cava.treble)
        emit(bars)
        frames += n
        let ahead = Double(frames) / Double(rate) - Date().timeIntervalSince(start)
        if ahead > 0 && !fast { Thread.sleep(forTimeInterval: ahead) }
    }
    exit(0)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr {
        log("\(what) failed (\(status))")
        exit(1)
    }
}

let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.uuid = UUID()
tapDescription.name = "rexui-visualiser"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted
var tap = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDescription, &tap), "creating the audio tap")

var format = AudioStreamBasicDescription()
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var formatAddress = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
check(AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format), "reading the tap's format")
let rate = Int(format.mSampleRate)
let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
let channels = Int(max(1, format.mChannelsPerFrame))

let aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey: "rexui-visualiser",
    kAudioAggregateDeviceUIDKey: "rexui-visualiser-" + UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
        ]
    ],
]
var device = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "creating the aggregate device")

let cava = makeCava(rate)
loadSens(cava)
saveCava = cava
var block = UInt32(256)
var blockSize = UInt32(4)
var blockAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyBufferFrameSize,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectSetPropertyData(device, &blockAddress, 0, nil, blockSize, &block)
AudioObjectGetPropertyData(device, &blockAddress, 0, nil, &blockSize, &block)
beat = Beat(fps: Double(rate) / Double(max(1, block)))
let work = DispatchQueue(label: "rexui-visualiser")

let silent = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
silent.initialize(to: false)
var proc: AudioDeviceIOProcID?
check(
    AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let data = first.mData else { return }
        var mono: [Float]
        if interleaved {
            let n = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            let p = data.assumingMemoryBound(to: Float.self)
            mono = [Float](repeating: 0, count: n)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += p[i * channels + c] }
                mono[i] = s / Float(channels)
            }
        } else {
            let n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            mono = [Float](repeating: 0, count: n)
            for buffer in list {
                guard let d = buffer.mData else { continue }
                let p = d.assumingMemoryBound(to: Float.self)
                for i in 0..<n { mono[i] += p[i] / Float(list.count) }
            }
        }
        if silent.pointee { mono = [Float](repeating: 0, count: mono.count) }
        work.async {
            let bars = cava.execute(mono[...])
            beat?.add(cava.treble)
            emit(bars)
        }
    }, "adding the audio callback")
check(AudioDeviceStart(device, proc), "starting the audio device")

var tapBundle = ""
var mutedBundles: [String] = []
var tapped: (exclusive: Bool, processes: [AudioObjectID])? = nil

func processPID(_ object: AudioObjectID) -> pid_t? {
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var pid = pid_t(0)
    var size = UInt32(MemoryLayout<pid_t>.size)
    return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &pid) == noErr ? pid : nil
}

func processBundle(_ object: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &s) == noErr, let s else { return "" }
    return s.takeRetainedValue() as String
}

func parentOf(_ pid: pid_t) -> pid_t {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    return sysctl(&mib, 4, &kp, &size, nil, 0) == 0 && size > 0 ? kp.kp_eproc.e_ppid : 0
}

let responsibleFor = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }

func audioProcesses(of bundle: String) -> [AudioObjectID] {
    let apps = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else {
        return []
    }
    return ids.filter { obj in
        guard let pid = processPID(obj) else { return false }
        let bid = processBundle(obj)
        if bid == bundle || bid.hasPrefix(bundle + ".") { return true }
        if let r = responsibleFor, apps.contains(r(pid)) { return true }
        var p = pid
        for _ in 0..<8 where p > 1 {
            if apps.contains(p) { return true }
            p = parentOf(p)
        }
        return false
    }.sorted()
}

func retarget() {
    silent.pointee = !tapBundle.isEmpty && mutedBundles.contains(tapBundle)
    let exclusive = tapBundle.isEmpty
    let processes =
        exclusive ? Array(Set(mutedBundles.flatMap(audioProcesses(of:)))).sorted() : audioProcesses(of: tapBundle)
    if let t = tapped, t.exclusive == exclusive, t.processes == processes { return }
    tapDescription.isExclusive = exclusive
    tapDescription.processes = processes
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var ref = Unmanaged.passUnretained(tapDescription).toOpaque()
    let st = AudioObjectSetPropertyData(tap, &a, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref)
    if st != noErr { return log("hearing \(tapBundle.isEmpty ? "everything" : tapBundle) failed (\(st))") }
    if tapped?.exclusive != exclusive {
        log(
            "hearing \(exclusive ? "everything but \(processes.count) muted processes" : "\(tapBundle) (\(processes.count) processes)")"
        )
    }
    tapped = (exclusive, processes)
}

var processListAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processListAddress, DispatchQueue.main) {
    _, _ in
    if !tapBundle.isEmpty || !mutedBundles.isEmpty { retarget() }
}

watchStdin({ m in
    let b = m["bundle"] as? String ?? tapBundle
    let muted = (m["muted"] as? [String] ?? mutedBundles).sorted()
    if b == tapBundle && muted == mutedBundles { return }
    tapBundle = b
    mutedBundles = muted
    retarget()
}) {
    AudioDeviceStop(device, proc)
    AudioDeviceDestroyIOProcID(device, proc!)
    AudioHardwareDestroyAggregateDevice(device)
    AudioHardwareDestroyProcessTap(tap)
}
dispatchMain()
