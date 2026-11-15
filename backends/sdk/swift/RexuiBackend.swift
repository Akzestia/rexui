// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import Darwin
import Foundation

public final class RexuiBackend {
    public enum Answer {
        case success(Any)
        case failure(String)
    }
    public var onMessage: ((Any) -> Void)?
    public var onCall: ((Any, @escaping (Answer) -> Void) -> Void)?
    public private(set) var protocol2 = false

    private let lock = NSLock()
    private var sent: [String: Any] = [:]
    private var held: [String: Any] = [:]
    private var credit = Int.max
    private var callsTakes = false
    private var input = [UInt8]()
    private var early = [String]()
    private static let frameMax = (1 << 20) - 64

    public init(features: [String] = ["patch", "call", "credit"]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let hello =
            "{\"rexui\":{\"protocol\":2,\"features\":[" + features.map { "\"\($0)\"" }.joined(separator: ",") + "]}}\n"
        write(Array(hello.utf8))
        while true {
            while let nl = input.firstIndex(of: 10) {
                let line = String(decoding: input[..<nl], as: UTF8.self)
                input.removeSubrange(...nl)
                if line.hasPrefix("{\"rexui\":") {
                    protocol2 = true
                    if let d = line.data(using: .utf8),
                        let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                        let r = o["rexui"] as? [String: Any]
                    {
                        let f = r["features"] as? [String] ?? []
                        callsTakes = f.contains("call")
                        if f.contains("credit") { credit = (r["credit"] as? Int) ?? 64 }
                    }
                    return
                }
                early.append(line)
            }
            guard fill() else { exit(0) }
        }
    }

    public func state(_ values: [String: Any?]) {
        lock.lock()
        defer { lock.unlock() }
        for (k, v) in values {
            let value: Any = v ?? NSNull()
            if let old = sent[k], (old as AnyObject).isEqual(value as AnyObject) {
                held.removeValue(forKey: k)
                continue
            }
            held[k] = value
        }
        flushHeld()
    }

    public func emit(_ obj: [String: Any]) {
        var rest = obj
        if let st = rest.removeValue(forKey: "state") as? [String: Any] { state(st.mapValues { Optional($0) }) }
        if !rest.isEmpty { message(rest) }
    }

    public func readLine() -> String? {
        if !early.isEmpty { return early.removeFirst() }
        while true {
            if protocol2 {
                while let (type, flags, seq, payload) = nextFrame() {
                    if type == 1 { return String(decoding: payload, as: UTF8.self) }
                    handle(type: type, flags: flags, seq: seq, payload: payload)
                }
            } else if let nl = input.firstIndex(of: 10) {
                let line = String(decoding: input[..<nl], as: UTF8.self)
                input.removeSubrange(...nl)
                return line
            }
            guard fill() else { return nil }
        }
    }

    public func message(_ value: Any) {
        guard let j = json(value) else { return }
        let b = Array(j.utf8)
        guard !protocol2 || b.count <= Self.frameMax else {
            say("a message of \(b.count) bytes, more than a frame holds (\(Self.frameMax)); not sent")
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if protocol2 { frame(type: 1, flags: 0, seq: 0, payload: b) } else { write(b + [10]) }
    }

    private func say(_ s: String) { FileHandle.standardError.write(Data(("rexui: " + s + "\n").utf8)) }

    private func flushHeld() {
        guard !held.isEmpty else { return }
        if !protocol2 {
            if let j = json(["state": held]) { write(Array((j + "\n").utf8)) }
            for (k, v) in held { sent[k] = v }
            held.removeAll()
            return
        }
        var entries = [(key: String, bytes: [UInt8])]()
        for (k, v) in held {
            let key = Array(k.utf8)
            guard !key.isEmpty, key.count <= 1024 else {
                held.removeValue(forKey: k)
                continue
            }
            var e = le16(UInt16(key.count)) + key
            switch v {
            case is NSNull: e.append(0)
            case let b as Bool
            where type(of: v) == Bool.self || (v as AnyObject) === kCFBooleanTrue
                || (v as AnyObject) === kCFBooleanFalse:
                e.append(b ? 2 : 1)
            case let n as NSNumber:
                e.append(3)
                e += le64(n.doubleValue.bitPattern)
            case let s as String:
                let b = Array(s.utf8)
                e.append(4)
                e += le32(UInt32(truncatingIfNeeded: b.count)) + b
            default:
                guard let j = json(v) else {
                    held.removeValue(forKey: k)
                    continue
                }
                let b = Array(j.utf8)
                e.append(5)
                e += le32(UInt32(truncatingIfNeeded: b.count)) + b
            }
            if e.count > Self.frameMax {
                say("state \(k.prefix(64)): \(e.count) bytes, more than a frame holds (\(Self.frameMax)); not sent")
                sent[k] = v
                held.removeValue(forKey: k)
                continue
            }
            entries.append((k, e))
        }
        var i = 0
        while i < entries.count, credit > 0 {
            var p = [UInt8]()
            let first = i
            while i < entries.count, p.count + entries[i].bytes.count <= Self.frameMax {
                p += entries[i].bytes
                i += 1
            }
            for e in entries[first..<i] { sent[e.key] = held.removeValue(forKey: e.key) }
            frame(type: 2, flags: 0, seq: 0, payload: p)
            if credit != Int.max { credit -= 1 }
        }
    }

    private func frame(type: UInt16, flags: UInt16, seq: UInt64, payload: [UInt8]) {
        write(le32(UInt32(payload.count)) + le16(type) + le16(flags) + le64(seq) + payload)
    }

    public func run() -> Never {
        for line in early + drainLines() { deliver(line) }
        early.removeAll()
        while true {
            if protocol2 {
                while let (type, flags, seq, payload) = nextFrame() {
                    handle(type: type, flags: flags, seq: seq, payload: payload)
                }
            } else {
                for line in drainLines() { deliver(line) }
            }
            guard fill() else { exit(0) }
        }
    }

    private func handle(type: UInt16, flags: UInt16, seq: UInt64, payload: [UInt8]) {
        switch type {
        case 1:
            deliver(String(decoding: payload, as: UTF8.self))
        case 3:
            let value = parse(payload)
            let reply: (Answer) -> Void = { [weak self] a in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                switch a {
                case .success(let v):
                    let j = Array((self.json(v) ?? "null").utf8)
                    if j.count <= Self.frameMax {
                        self.frame(type: 4, flags: 0, seq: seq, payload: j)
                    } else {
                        self.frame(
                            type: 4, flags: 1, seq: seq,
                            payload: Array("\"the answer is more than a frame holds\"".utf8))
                    }
                case .failure(let why):
                    let j = Array((self.json(String(why.prefix(65536))) ?? "\"\"").utf8)
                    self.frame(type: 4, flags: 1, seq: seq, payload: j)
                }
            }
            if let onCall { onCall(value, reply) } else { reply(.failure("this backend takes no calls")) }
        case 5:
            guard payload.count == 4 else { return }
            lock.lock()
            let more = Int(payload[0]) | Int(payload[1]) << 8 | Int(payload[2]) << 16 | Int(payload[3]) << 24
            if credit != Int.max { credit += more }
            flushHeld()
            lock.unlock()
        default: break
        }
    }

    private func deliver(_ line: String) {
        guard let onMessage else { return }
        onMessage(parse(Array(line.utf8)))
    }

    private func parse(_ b: [UInt8]) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(b), options: .fragmentsAllowed))
            ?? String(decoding: b, as: UTF8.self)
    }

    private func json(_ v: Any) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func fill() -> Bool {
        var b = [UInt8](repeating: 0, count: 65536)
        let n = read(0, &b, b.count)
        if n <= 0 { return false }
        input += b[..<n]
        return true
    }

    private func drainLines() -> [String] {
        var out = [String]()
        while let nl = input.firstIndex(of: 10) {
            out.append(String(decoding: input[..<nl], as: UTF8.self))
            input.removeSubrange(...nl)
        }
        return out
    }

    private func nextFrame() -> (UInt16, UInt16, UInt64, [UInt8])? {
        guard input.count >= 16 else { return nil }
        let len = Int(u32(0))
        if len > (1 << 20) - 64 { exit(1) }
        guard input.count >= 16 + len else { return nil }
        let type = UInt16(input[4]) | UInt16(input[5]) << 8
        let flags = UInt16(input[6]) | UInt16(input[7]) << 8
        let seq = UInt64(u32(8)) | UInt64(u32(12)) << 32
        let payload = Array(input[16..<(16 + len)])
        input.removeSubrange(..<(16 + len))
        return (type, flags, seq, payload)
    }

    private func u32(_ at: Int) -> UInt32 {
        UInt32(input[at]) | UInt32(input[at + 1]) << 8 | UInt32(input[at + 2]) << 16 | UInt32(input[at + 3]) << 24
    }

    private func write(_ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(1, $0.baseAddress, $0.count) }
            if n <= 0 { exit(0) }
            off += n
        }
    }
}

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
private func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
