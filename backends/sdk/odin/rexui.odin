// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

REXUI_FRAME_MAX :: (1 << 20) - 64

Rexui_Next :: enum {
	Message,
	Timeout,
	Closed,
}

Rexui_Key :: struct {
	name: string,
	sent: Maybe(string),
	held: Maybe(string),
}

@(private = "file") rx_keys: [dynamic]Rexui_Key
@(private = "file") rx_credit: i64 = -1
@(private = "file") rx_in: [dynamic]byte
@(private = "file") rx_pending: int
@(private = "file") rx_early: [dynamic]string
@(private = "file") rx_early_at: int

rexui_on_call: proc(seq: u64, json: string) = nil

@(private = "file")
rx_write :: proc(b: []byte) {
	off := 0
	for off < len(b) {
		n, err := os.write(os.stdout, b[off:])
		if n <= 0 || err != nil do os.exit(0)
		off += n
	}
}

@(private = "file")
rx_put :: proc(b: ^[dynamic]byte, v: u64, n: int) {
	for i in 0 ..< n do append(b, byte(v >> (8 * uint(i))))
}

@(private = "file")
rx_frame :: proc(kind: u16, flags: u16, seq: u64, payload: []byte) {
	b: [dynamic]byte
	defer delete(b)
	rx_put(&b, u64(len(payload)), 4)
	rx_put(&b, u64(kind), 2)
	rx_put(&b, u64(flags), 2)
	rx_put(&b, seq, 8)
	append(&b, ..payload)
	rx_write(b[:])
}

@(private = "file")
rx_get :: proc(b: []byte, n: int) -> u64 {
	v: u64
	for i in 0 ..< n do v |= u64(b[i]) << (8 * uint(i))
	return v
}

@(private = "file")
rx_fill :: proc() -> bool {
	buf: [65536]byte
	n, err := os.read(os.stdin, buf[:])
	if n <= 0 || err != nil do return false
	append(&rx_in, ..buf[:n])
	return true
}

rexui_begin :: proc() {
	rx_write(transmute([]byte)string(`{"rexui":{"protocol":2,"features":["patch","call","credit"]}}` + "\n"))
	for {
		for {
			nl := -1
			for c, i in rx_in do if c == '\n' {nl = i; break}
			if nl < 0 do break
			line := strings.clone(string(rx_in[:nl]))
			remove_range(&rx_in, 0, nl + 1)
			if strings.has_prefix(line, `{"rexui":`) {
				if at := strings.index(line, `"credit":`); at >= 0 {
					e := at + 9
					for e < len(line) && line[e] >= '0' && line[e] <= '9' do e += 1
					if v, ok := strconv.parse_i64(line[at + 9:e]); ok do rx_credit = v
				}
				return
			}
			append(&rx_early, line)
		}
		if !rx_fill() do os.exit(0)
	}
}

rexui_message :: proc(json: string) {
	if len(json) > REXUI_FRAME_MAX {
		fmt.eprintfln("rexui: a message of %d bytes, more than a frame holds (%d); not sent", len(json), REXUI_FRAME_MAX)
		return
	}
	rx_frame(1, 0, 0, transmute([]byte)json)
}

rexui_reply :: proc(seq: u64, err: bool, json: string) {
	if len(json) > REXUI_FRAME_MAX {
		rx_frame(4, 1, seq, transmute([]byte)string(`"the answer is more than a frame holds"`))
		return
	}
	rx_frame(4, err ? 1 : 0, seq, transmute([]byte)json)
}

rexui_next :: proc(ms: int) -> (string, Rexui_Next) {
	if rx_early_at < len(rx_early) {
		rx_early_at += 1
		return rx_early[rx_early_at - 1], .Message
	}
	if rx_pending > 0 {
		remove_range(&rx_in, 0, rx_pending)
		rx_pending = 0
	}
	for {
		for len(rx_in) < 16 || len(rx_in) < 16 + int(rx_get(rx_in[:], 4)) {
			if len(rx_in) >= 16 && rx_get(rx_in[:], 4) > REXUI_FRAME_MAX do os.exit(1)
			if ms >= 0 {
				fds := [1]posix.pollfd{{fd = 0, events = {.IN}}}
				if posix.poll(&fds[0], 1, i32(ms)) == 0 do return "", .Timeout
			}
			if !rx_fill() do return "", .Closed
		}
		n := int(rx_get(rx_in[:], 4))
		kind := u16(rx_get(rx_in[4:], 2))
		seq := rx_get(rx_in[8:], 8)
		payload := string(rx_in[16:16 + n])
		switch kind {
		case 1:
			rx_pending = 16 + n
			return payload, .Message
		case 3:
			if rexui_on_call != nil do rexui_on_call(seq, payload)
			else do rexui_reply(seq, true, `"this backend takes no calls"`)
		case 5:
			if n == 4 {
				if rx_credit >= 0 do rx_credit += i64(rx_get(rx_in[16:], 4))
				rx_flush()
			}
		}
		remove_range(&rx_in, 0, 16 + n)
	}
}

@(private = "file")
rx_ws :: proc(c: byte) -> bool {return c == ' ' || c == '\n' || c == '\t' || c == '\r'}

rexui_state_json :: proc(t: string) {
	i := 0
	for i < len(t) && rx_ws(t[i]) do i += 1
	if i >= len(t) || t[i] != '{' do return
	i += 1
	for {
		for i < len(t) && (rx_ws(t[i]) || t[i] == ',') do i += 1
		if i >= len(t) || t[i] != '"' do break
		ks := i + 1
		i = ks
		for i < len(t) && t[i] != '"' do i += t[i] == '\\' ? 2 : 1
		if i >= len(t) do break
		key := t[ks:i]
		i += 1
		for i < len(t) && (rx_ws(t[i]) || t[i] == ':') do i += 1
		vs := i
		depth := 0
		in_str := false
		scan: for i < len(t) {
			c := t[i]
			if in_str {
				if c == '\\' {
					i += 1
				} else if c == '"' {
					in_str = false
					if depth == 0 {i += 1; break scan}
				}
			} else if c == '"' {
				in_str = true
			} else if c == '{' || c == '[' {
				depth += 1
			} else if c == '}' || c == ']' {
				if depth == 0 do break scan
				depth -= 1
				if depth == 0 {i += 1; break scan}
			} else if c == ',' && depth == 0 {
				break scan
			}
			i += 1
		}
		ve := min(i, len(t))
		for ve > vs && rx_ws(t[ve - 1]) do ve -= 1
		if ve == vs do break
		rx_hold(key, t[vs:ve])
	}
	rx_flush()
}

@(private = "file")
rx_hold :: proc(key, v: string) {
	if len(key) == 0 || len(key) > 1024 do return
	k: ^Rexui_Key
	for &x in rx_keys do if x.name == key {k = &x; break}
	if k == nil {
		append(&rx_keys, Rexui_Key{name = strings.clone(key)})
		k = &rx_keys[len(rx_keys) - 1]
	}
	if h, ok := k.held.?; ok do delete(h)
	k.held = nil
	if s, ok := k.sent.?; ok && s == v do return
	k.held = strings.clone(v)
}

@(private = "file")
rx_flush :: proc() {
	for &k in rx_keys {
		v := k.held.? or_continue
		if 7 + len(k.name) + len(v) <= REXUI_FRAME_MAX do continue
		fmt.eprintfln("rexui: state %s: %d bytes, more than a frame holds (%d); not sent", k.name[:min(len(k.name), 64)], len(v), REXUI_FRAME_MAX)
		if s, ok := k.sent.?; ok do delete(s)
		k.sent = v
		k.held = nil
	}
	for rx_credit != 0 {
		p: [dynamic]byte
		defer delete(p)
		for &k in rx_keys {
			v := k.held.? or_continue
			if len(p) + 7 + len(k.name) + len(v) > REXUI_FRAME_MAX do continue
			rx_put(&p, u64(len(k.name)), 2)
			append(&p, ..transmute([]byte)k.name)
			append(&p, 5)
			rx_put(&p, u64(len(v)), 4)
			append(&p, ..transmute([]byte)v)
			if s, ok := k.sent.?; ok do delete(s)
			k.sent = v
			k.held = nil
		}
		if len(p) == 0 do return
		rx_frame(2, 0, 0, p[:])
		if rx_credit > 0 do rx_credit -= 1
	}
}
