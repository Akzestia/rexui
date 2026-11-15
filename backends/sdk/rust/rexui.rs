#![allow(dead_code)]
// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT

use std::io::{Read, Write};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

const FRAME_MAX: usize = (1 << 20) - 64;
const MESSAGE: u16 = 1;
const STATE_PATCH: u16 = 2;
const CALL: u16 = 3;
const REPLY: u16 = 4;
const CREDIT: u16 = 5;
const V_JSON: u8 = 5;

pub enum Next {
    Message(String),
    Timeout,
    Closed,
}

struct Key {
    name: String,
    sent: Option<String>,
    held: Option<String>,
}

struct State {
    keys: Vec<Key>,
    credit: i64,
}

type CallFn = Box<dyn Fn(&str) -> Result<String, String> + Send + Sync>;

static STATE: OnceLock<Mutex<State>> = OnceLock::new();
static OUT: Mutex<()> = Mutex::new(());
static MESSAGES: OnceLock<Mutex<Receiver<Option<String>>>> = OnceLock::new();
static ON_CALL: OnceLock<CallFn> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| Mutex::new(State { keys: Vec::new(), credit: -1 }))
}

fn write_all(b: &[u8]) {
    let mut out = std::io::stdout().lock();
    if out.write_all(b).and_then(|_| out.flush()).is_err() {
        std::process::exit(0);
    }
}

fn frame(kind: u16, flags: u16, seq: u64, payload: &[u8]) {
    let _g = OUT.lock().unwrap();
    let mut b = Vec::with_capacity(16 + payload.len());
    b.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    b.extend_from_slice(&kind.to_le_bytes());
    b.extend_from_slice(&flags.to_le_bytes());
    b.extend_from_slice(&seq.to_le_bytes());
    b.extend_from_slice(payload);
    write_all(&b);
}

pub fn begin() {
    write_all(b"{\"rexui\":{\"protocol\":2,\"features\":[\"patch\",\"call\",\"credit\"]}}\n");
    let mut stdin = std::io::stdin().lock();
    let mut buf: Vec<u8> = Vec::new();
    let mut early = Vec::new();
    let mut chunk = [0u8; 65536];
    loop {
        while let Some(nl) = buf.iter().position(|&c| c == b'\n') {
            let line: Vec<u8> = buf.drain(..=nl).collect();
            let text = String::from_utf8_lossy(&line[..line.len() - 1]).into_owned();
            if text.starts_with("{\"rexui\":") {
                if let Some(at) = text.find("\"credit\":") {
                    let n: String = text[at + 9..].chars().take_while(|c| c.is_ascii_digit()).collect();
                    state().lock().unwrap().credit = n.parse().unwrap_or(-1);
                }
                drop(stdin);
                return reader(buf, early);
            }
            early.push(text);
        }
        match stdin.read(&mut chunk) {
            Ok(0) | Err(_) => std::process::exit(0),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
}

fn reader(mut buf: Vec<u8>, early: Vec<String>) {
    let (tx, rx) = channel();
    for e in early {
        let _ = tx.send(Some(e));
    }
    let _ = MESSAGES.set(Mutex::new(rx));
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin().lock();
        let mut chunk = [0u8; 65536];
        loop {
            while buf.len() >= 16 {
                let len = u32::from_le_bytes(buf[0..4].try_into().unwrap()) as usize;
                if len > FRAME_MAX {
                    std::process::exit(1);
                }
                if buf.len() < 16 + len {
                    break;
                }
                let kind = u16::from_le_bytes(buf[4..6].try_into().unwrap());
                let seq = u64::from_le_bytes(buf[8..16].try_into().unwrap());
                let payload: Vec<u8> = buf[16..16 + len].to_vec();
                buf.drain(..16 + len);
                match kind {
                    MESSAGE => {
                        let _ = tx.send(Some(String::from_utf8_lossy(&payload).into_owned()));
                    }
                    CREDIT if payload.len() == 4 => {
                        let more = u32::from_le_bytes(payload[..4].try_into().unwrap()) as i64;
                        let mut s = state().lock().unwrap();
                        if s.credit >= 0 {
                            s.credit += more;
                        }
                        flush(&mut s);
                    }
                    CALL => {
                        let value = String::from_utf8_lossy(&payload).into_owned();
                        let answer = match ON_CALL.get() {
                            Some(f) => f(&value),
                            None => Err("this backend takes no calls".into()),
                        };
                        reply(seq, answer);
                    }
                    _ => {}
                }
            }
            match stdin.read(&mut chunk) {
                Ok(0) | Err(_) => {
                    let _ = tx.send(None);
                    return;
                }
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
            }
        }
    });
}

pub fn on_call(f: impl Fn(&str) -> Result<String, String> + Send + Sync + 'static) {
    let _ = ON_CALL.set(Box::new(f));
}

pub fn reply(seq: u64, answer: Result<String, String>) {
    match answer {
        Ok(json) if json.len() <= FRAME_MAX => frame(REPLY, 0, seq, json.as_bytes()),
        Ok(_) => frame(REPLY, 1, seq, b"\"the answer is more than a frame holds\""),
        Err(why) => {
            let q = quote(&why);
            frame(REPLY, 1, seq, if q.len() <= FRAME_MAX { q.as_bytes() } else { b"\"the reason is more than a frame holds\"" });
        }
    }
}

pub fn message(json: &str) -> bool {
    if json.len() > FRAME_MAX {
        eprintln!("rexui: a message of {} bytes, more than a frame holds ({FRAME_MAX}); not sent", json.len());
        return false;
    }
    frame(MESSAGE, 0, 0, json.as_bytes());
    true
}

pub fn next(within: Option<Duration>) -> Next {
    let Some(rx) = MESSAGES.get() else { return Next::Closed };
    let rx = rx.lock().unwrap();
    let got = match within {
        Some(d) => match rx.recv_timeout(d) {
            Ok(m) => m,
            Err(RecvTimeoutError::Timeout) => return Next::Timeout,
            Err(RecvTimeoutError::Disconnected) => None,
        },
        None => rx.recv().ok().flatten(),
    };
    match got {
        Some(m) => Next::Message(m),
        None => Next::Closed,
    }
}

pub fn state_json(obj: &str) {
    let Some(pairs) = split(obj) else { return };
    let mut s = state().lock().unwrap();
    for (k, v) in pairs {
        let i = match s.keys.iter().position(|x| x.name == k) {
            Some(i) => i,
            None => {
                if k.is_empty() || k.len() > 1024 {
                    continue;
                }
                s.keys.push(Key { name: k.to_string(), sent: None, held: None });
                s.keys.len() - 1
            }
        };
        let key = &mut s.keys[i];
        if key.sent.as_deref() == Some(v) {
            key.held = None;
        } else {
            key.held = Some(v.to_string());
        }
    }
    flush(&mut s);
}

fn flush(s: &mut State) {
    for k in s.keys.iter_mut() {
        if let Some(v) = &k.held {
            if 7 + k.name.len() + v.len() > FRAME_MAX {
                let name: String = k.name.chars().take(64).collect();
                eprintln!("rexui: state {name}: {} bytes, more than a frame holds ({FRAME_MAX}); not sent", v.len());
                k.sent = k.held.take();
            }
        }
    }
    while s.credit != 0 {
        let mut p = Vec::new();
        for k in s.keys.iter_mut() {
            let Some(v) = &k.held else { continue };
            if p.len() + 7 + k.name.len() + v.len() > FRAME_MAX {
                continue;
            }
            p.extend_from_slice(&(k.name.len() as u16).to_le_bytes());
            p.extend_from_slice(k.name.as_bytes());
            p.push(V_JSON);
            p.extend_from_slice(&(v.len() as u32).to_le_bytes());
            p.extend_from_slice(v.as_bytes());
            k.sent = k.held.take();
        }
        if p.is_empty() {
            return;
        }
        frame(STATE_PATCH, 0, 0, &p);
        if s.credit > 0 {
            s.credit -= 1;
        }
    }
}

fn split(t: &str) -> Option<Vec<(&str, &str)>> {
    let b = t.as_bytes();
    let ws = |c: u8| c == b' ' || c == b'\n' || c == b'\t' || c == b'\r';
    let mut i = 0;
    while i < b.len() && ws(b[i]) {
        i += 1;
    }
    if i >= b.len() || b[i] != b'{' {
        return None;
    }
    i += 1;
    let mut out = Vec::new();
    loop {
        while i < b.len() && (ws(b[i]) || b[i] == b',') {
            i += 1;
        }
        if i >= b.len() || b[i] != b'"' {
            break;
        }
        let ks = i + 1;
        i = ks;
        while i < b.len() && b[i] != b'"' {
            i += if b[i] == b'\\' { 2 } else { 1 };
        }
        if i >= b.len() {
            break;
        }
        let key = &t[ks..i];
        i += 1;
        while i < b.len() && (ws(b[i]) || b[i] == b':') {
            i += 1;
        }
        let vs = i;
        let (mut depth, mut in_str) = (0i32, false);
        while i < b.len() {
            let c = b[i];
            if in_str {
                if c == b'\\' {
                    i += 1;
                } else if c == b'"' {
                    in_str = false;
                    if depth == 0 {
                        i += 1;
                        break;
                    }
                }
            } else if c == b'"' {
                in_str = true;
            } else if c == b'{' || c == b'[' {
                depth += 1;
            } else if c == b'}' || c == b']' {
                if depth == 0 {
                    break;
                }
                depth -= 1;
                if depth == 0 {
                    i += 1;
                    break;
                }
            } else if c == b',' && depth == 0 {
                break;
            }
            i += 1;
        }
        let mut ve = i.min(b.len());
        while ve > vs && ws(b[ve - 1]) {
            ve -= 1;
        }
        if ve == vs {
            break;
        }
        out.push((key, &t[vs..ve]));
    }
    Some(out)
}

fn quote(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}
