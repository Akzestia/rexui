// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
const std = @import("std");
const c = std.c;

const frame_max: usize = (1 << 20) - 64;
const max_keys = 256;

const Key = struct {
    name: []u8 = &.{},
    sent: ?[]u8 = null,
    held: ?[]u8 = null,
};

var keys: [max_keys]Key = undefined;
var nkeys: usize = 0;
var credit: i64 = -1;
var in_buf: [1 << 21]u8 = undefined;
var in_len: usize = 0;
var pending: usize = 0;
var early: [64][]u8 = undefined;
var nearly: usize = 0;
var early_at: usize = 0;
const gpa = std.heap.c_allocator;

pub var onCall: ?*const fn (seq: u64, json: []const u8) void = null;

pub const Next = union(enum) { message: []const u8, timeout, closed };

fn writeAll(b: []const u8) void {
    var off: usize = 0;
    while (off < b.len) {
        const w = c.write(1, b[off..].ptr, b.len - off);
        if (w <= 0) c.exit(0);
        off += @intCast(w);
    }
}

fn frame(kind: u16, flags: u16, seq: u64, payload: []const u8) void {
    var h: [16]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u16, h[4..6], kind, .little);
    std.mem.writeInt(u16, h[6..8], flags, .little);
    std.mem.writeInt(u64, h[8..16], seq, .little);
    writeAll(&h);
    writeAll(payload);
}

fn fill() bool {
    if (in_len == in_buf.len) c.exit(1);
    const n = c.read(0, in_buf[in_len..].ptr, in_buf.len - in_len);
    if (n <= 0) return false;
    in_len += @intCast(n);
    return true;
}

fn eat(n: usize) void {
    std.mem.copyForwards(u8, in_buf[0 .. in_len - n], in_buf[n..in_len]);
    in_len -= n;
}

pub fn begin() void {
    writeAll("{\"rexui\":{\"protocol\":2,\"features\":[\"patch\",\"call\",\"credit\"]}}\n");
    while (true) {
        while (std.mem.indexOfScalar(u8, in_buf[0..in_len], '\n')) |nl| {
            const line = in_buf[0..nl];
            if (std.mem.startsWith(u8, line, "{\"rexui\":")) {
                if (std.mem.indexOf(u8, line, "\"credit\":")) |at| {
                    var e = at + 9;
                    while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
                    credit = std.fmt.parseInt(i64, line[at + 9 .. e], 10) catch -1;
                }
                eat(nl + 1);
                return;
            }
            if (nearly < early.len) {
                early[nearly] = gpa.dupe(u8, line) catch c.exit(1);
                nearly += 1;
            }
            eat(nl + 1);
        }
        if (!fill()) c.exit(0);
    }
}

pub fn message(json: []const u8) void {
    if (json.len > frame_max) {
        std.debug.print("rexui: a message of {d} bytes, more than a frame holds ({d}); not sent\n", .{ json.len, frame_max });
        return;
    }
    frame(1, 0, 0, json);
}

pub fn reply(seq: u64, err: bool, json: []const u8) void {
    if (json.len > frame_max) return frame(4, 1, seq, "\"the answer is more than a frame holds\"");
    frame(4, if (err) 1 else 0, seq, json);
}

pub fn next(ms: i32) Next {
    if (early_at < nearly) {
        early_at += 1;
        return .{ .message = early[early_at - 1] };
    }
    if (pending > 0) {
        eat(pending);
        pending = 0;
    }
    while (true) {
        while (in_len < 16 or in_len < 16 + std.mem.readInt(u32, in_buf[0..4], .little)) {
            if (in_len >= 16 and std.mem.readInt(u32, in_buf[0..4], .little) > frame_max) c.exit(1);
            if (ms >= 0) {
                var fds = [_]c.pollfd{.{ .fd = 0, .events = c.POLL.IN, .revents = 0 }};
                if (c.poll(&fds, 1, ms) == 0) return .timeout;
            }
            if (!fill()) return .closed;
        }
        const len: usize = std.mem.readInt(u32, in_buf[0..4], .little);
        const kind = std.mem.readInt(u16, in_buf[4..6], .little);
        const seq = std.mem.readInt(u64, in_buf[8..16], .little);
        const payload = in_buf[16 .. 16 + len];
        switch (kind) {
            1 => {
                pending = 16 + len;
                return .{ .message = payload };
            },
            3 => if (onCall) |f| f(seq, payload) else reply(seq, true, "\"this backend takes no calls\""),
            5 => if (len == 4) {
                if (credit >= 0) credit += std.mem.readInt(u32, payload[0..4], .little);
                flush();
            },
            else => {},
        }
        eat(16 + len);
    }
}

pub fn stateJson(t: []const u8) void {
    var i: usize = 0;
    while (i < t.len and isWs(t[i])) i += 1;
    if (i >= t.len or t[i] != '{') return;
    i += 1;
    while (true) {
        while (i < t.len and (isWs(t[i]) or t[i] == ',')) i += 1;
        if (i >= t.len or t[i] != '"') break;
        const ks = i + 1;
        i = ks;
        while (i < t.len and t[i] != '"') i += if (t[i] == '\\') 2 else 1;
        if (i >= t.len) break;
        const key = t[ks..i];
        i += 1;
        while (i < t.len and (isWs(t[i]) or t[i] == ':')) i += 1;
        const vs = i;
        var depth: i32 = 0;
        var in_str = false;
        while (i < t.len) : (i += 1) {
            const ch = t[i];
            if (in_str) {
                if (ch == '\\') {
                    i += 1;
                } else if (ch == '"') {
                    in_str = false;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            } else if (ch == '"') {
                in_str = true;
            } else if (ch == '{' or ch == '[') {
                depth += 1;
            } else if (ch == '}' or ch == ']') {
                if (depth == 0) break;
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            } else if (ch == ',' and depth == 0) break;
        }
        var ve = @min(i, t.len);
        while (ve > vs and isWs(t[ve - 1])) ve -= 1;
        if (ve == vs) break;
        hold(key, t[vs..ve]);
    }
    flush();
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
}

fn hold(key: []const u8, v: []const u8) void {
    if (key.len == 0 or key.len > 1024) return;
    var k: *Key = for (keys[0..nkeys]) |*x| {
        if (std.mem.eql(u8, x.name, key)) break x;
    } else blk: {
        if (nkeys == max_keys) return;
        keys[nkeys] = .{ .name = gpa.dupe(u8, key) catch return };
        nkeys += 1;
        break :blk &keys[nkeys - 1];
    };
    if (k.held) |h| gpa.free(h);
    k.held = null;
    if (k.sent) |s| if (std.mem.eql(u8, s, v)) return;
    k.held = gpa.dupe(u8, v) catch null;
}

fn flush() void {
    for (keys[0..nkeys]) |*k| {
        const v = k.held orelse continue;
        if (7 + k.name.len + v.len <= frame_max) continue;
        std.debug.print("rexui: state {s}: {d} bytes, more than a frame holds ({d}); not sent\n", .{ k.name[0..@min(k.name.len, 64)], v.len, frame_max });
        if (k.sent) |s| gpa.free(s);
        k.sent = v;
        k.held = null;
    }
    while (credit != 0) {
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(gpa);
        for (keys[0..nkeys]) |*k| {
            const v = k.held orelse continue;
            if (p.items.len + 7 + k.name.len + v.len > frame_max) continue;
            var n2: [2]u8 = undefined;
            std.mem.writeInt(u16, &n2, @intCast(k.name.len), .little);
            var n4: [4]u8 = undefined;
            std.mem.writeInt(u32, &n4, @intCast(v.len), .little);
            p.appendSlice(gpa, &n2) catch return;
            p.appendSlice(gpa, k.name) catch return;
            p.append(gpa, 5) catch return;
            p.appendSlice(gpa, &n4) catch return;
            p.appendSlice(gpa, v) catch return;
            if (k.sent) |s| gpa.free(s);
            k.sent = v;
            k.held = null;
        }
        if (p.items.len == 0) return;
        frame(2, 0, 0, p.items);
        if (credit > 0) credit -= 1;
    }
}
