# Backends and their SDKs

A backend is any program a `.rui` file runs with a `Process` that speaks rexui's protocol: it's how a dock gets data
from the Mac (CPU, music, a chat room) and does things (play, send, write a file). rexui knows nothing about any
particular backend: it runs the program, merges the state it sends into the Process's `state`, and passes messages
both ways. The contract in full is [backends/README.md](../../backends/README.md); this page is its API.

```qml
Process { id: clock; command: ["mine-clock"] }                 // a backend: say hello, send state
Text { text: clock.state.time || "" }                          // bound to what it sends
Button { text: qsTr("Reset"); onClicked: clock.send({ cmd: "reset" }) }
Button { text: qsTr("Ask"); onClicked: clock.call({ q: "zone" }).then((r) => zone = r.zone, (why) => console.warn(why)) }
Process { command: ["mine-clock"]; onMessage: if (message.event === "alarm") ring() }
```

## The protocol (2)

1. **The hello.** The backend's first line on stdout: `{"rexui":{"protocol":2,"features":["patch","call","credit"]}}`.
   rexui answers on stdin with the same shape and what it took (`"credit": 64`). From then on both pipes carry frames.
2. **Frames.** A 16-byte header (`u32 len | u16 type | u16 flags | u64 seq`, little endian), then the payload:
   - `STATE_PATCH` (out): the state keys that changed, merged into the element's `state`.
   - `MESSAGE` (both ways): one JSON value: the dock's `onMessage(message)`, and its `send(obj)`.
   - `CALL` / `REPLY`: a dock's `call(value)` (a promise) and the backend's answer, by `seq`; a reply flagged as an
     error rejects it, its reason a JSON string.
   - `CREDIT` (in): how many more frames the backend may send. Out of credit, it keeps its latest state and sends one
     patch when credit comes, so nothing queues while the dock is busy.
3. **Exit when stdin closes.** That's how rexui stops a backend: its dock reloaded, or Rex quit. stderr goes to
   `~/Library/Logs/rexui.log`. A backend that exits is started again (1 s, backing off to 30 s), and one whose program
   file changes is restarted on the new build.

The format is [backends/include/rexui_proto.h](../../backends/include/rexui_proto.h). You don't need to write it
yourself: each SDK below is one file, standard library only, the same API in every language. A program that never
says hello is a plain program: each line it prints reaches `onMessage` (parsed as JSON when it is), and nothing merges
into `state`.

## Swift

[backends/sdk/swift/RexuiBackend.swift](../../backends/sdk/swift/RexuiBackend.swift), Foundation only.

| | |
|-|-|
| `RexuiBackend(features:)` | says hello and reads rexui's answer |
| `state(_ values: [String: Any?])` | the state: only keys whose value changed since the last are sent (`nil` sends null) |
| `message(_ value: Any)` | one message to the dock (`onMessage`) |
| `emit(_ obj: [String: Any])` | an old-style JSON line: its `"state"` a patch, any other keys a message |
| `onMessage: ((Any) -> Void)?` | the dock's `send(obj)`, parsed (a String when it isn't JSON) |
| `onCall: ((Any, (Answer) -> Void) -> Void)?` | the dock's `call(value)`; answer once, `.success(value)` or `.failure(reason)` |
| `run() -> Never` | reads stdin and dispatches until it closes, then exits |
| `readLine() -> String?` | for a backend with its own loop: the next message's JSON text, `nil` once stdin closes |

```swift
import Foundation

let rexui = RexuiBackend()
rexui.onMessage = { msg in
    if let m = msg as? [String: Any], m["cmd"] as? String == "reset" { start = Date() }
}
rexui.onCall = { value, reply in reply(.success(["zone": TimeZone.current.identifier])) }
var start = Date()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    rexui.state(["time": DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium),
                 "uptime": Int(Date().timeIntervalSince(start))])
}
rexui.run()
```

## C, C++ and Objective-C

[backends/sdk/c/rexui_backend.h](../../backends/sdk/c/rexui_backend.h), header only, with `rexui_proto.h`. Writes take a
lock (any thread may write); read from one thread.

| | |
|-|-|
| `void rexui_begin(void)` | the hello, then rexui's answer: first, before anything else |
| `int rexui_state_json(const char *json, size_t n)` | a state object as JSON text: only its keys whose value changed go out |
| `int rexui_message(const char *json, size_t n)` | one message (`onMessage`'s) |
| `long rexui_read(const char **msg)` | the dock's next message (its JSON), its length; -1 when stdin closed |
| `long rexui_read_for(const char **msg, int ms)` | the same, or -2 when none came within `ms` |
| `void rexui_on_call(void (*fn)(uint64_t seq, const char *json, size_t n))` | the handler of a dock's `call(value)` (without one, calls are rejected) |
| `void rexui_reply(uint64_t seq, int error, const char *json, size_t n)` | the answer to call `seq` (`error`: a rejection, its reason as a JSON string) |

```c
#include "rexui_backend.h"
#include <stdio.h>

int main(void) {
    rexui_begin();
    for (int n = 0;; n++) {
        char buf[64];
        int len = snprintf(buf, sizeof buf, "{\"count\":%d}", n);
        rexui_state_json(buf, (size_t)len);
        const char *msg;
        long got = rexui_read_for(&msg, 1000);  // a message, or a second gone by
        if (got == -1) return 0;                // stdin closed: rexui stopped us
    }
}
```

## Rust

[backends/sdk/rust/rexui.rs](../../backends/sdk/rust/rexui.rs), std only: `mod rexui;` beside your `main.rs`.

| | |
|-|-|
| `rexui::begin()` | the hello, then rexui's answer |
| `rexui::state_json(obj: &str)` | a state object as JSON text: only the keys that changed go out |
| `rexui::message(json: &str) -> bool` | one message |
| `rexui::next(within: Option<Duration>) -> Next` | `Next::Message(json)`, `Next::Timeout` or `Next::Closed` |
| `rexui::on_call(f: impl Fn(&str) -> Result<String, String>)` | answers each `call(value)`: `Ok(json)` or `Err(reason)` |
| `rexui::reply(seq, Result<String, String>)` | an answer given later, by its call's seq |

```rust
mod rexui;
use std::time::Duration;

fn main() {
    rexui::begin();
    rexui::on_call(|value| Ok(format!(r#"{{"echo":{value}}}"#)));
    let mut n = 0;
    loop {
        rexui::state_json(&format!(r#"{{"count":{n}}}"#));
        match rexui::next(Some(Duration::from_secs(1))) {
            rexui::Next::Message(json) => eprintln!("got {json}"),
            rexui::Next::Timeout => n += 1,
            rexui::Next::Closed => return,
        }
    }
}
```

## Zig

[backends/sdk/zig/rexui.zig](../../backends/sdk/zig/rexui.zig), std and libc only: `const rexui = @import("rexui.zig");`.

| | |
|-|-|
| `rexui.begin()` | the hello, then rexui's answer |
| `rexui.stateJson(json)` | a state object: only the keys that changed go out |
| `rexui.message(json)` | one message |
| `rexui.next(ms) Next` | `.message`, `.timeout` or `.closed` (`ms` -1: as long as it takes) |
| `rexui.onCall`, `rexui.reply(seq, err, json)` | a dock's calls: set `onCall` to `fn (seq, json) void`, answer with `reply` |

```zig
const rexui = @import("rexui.zig");

pub fn main() void {
    rexui.begin();
    rexui.stateJson("{\"ready\":true}");
    while (true) switch (rexui.next(1000)) {
        .message => |json| rexui.message(json), // echo it back
        .timeout => {},
        .closed => return,
    };
}
```

## Odin

[backends/sdk/odin/rexui.odin](../../backends/sdk/odin/rexui.odin), core only: in the same package as your `main.odin`.

| | |
|-|-|
| `rexui_begin()` | the hello, then rexui's answer |
| `rexui_state_json(json)` | a state object: only the keys that changed go out |
| `rexui_message(json)` | one message |
| `rexui_next(ms) -> (string, Rexui_Next)` | the next message and `.Message`, `.Timeout` or `.Closed` |
| `rexui_on_call`, `rexui_reply(seq, err, json)` | a dock's calls and their answers |

```odin
package main

main :: proc() {
    rexui_begin()
    rexui_state_json(`{"ready":true}`)
    for {
        msg, got := rexui_next(1000)
        if got == .Closed do return
        if got == .Message do rexui_message(msg)
    }
}
```

## Frames in shared memory

For data that changes every display frame (a visualiser's bars, a graph), even a state patch costs a parse and a
binding per frame. [backends/include/rexui_frames.h](../../backends/include/rexui_frames.h) (C, header only, usable
from any language with a C FFI) is a wait-free triple buffer in POSIX shared memory: the backend writes each frame into
its back buffer and publishes it; rexui takes the newest frame on each display frame, with no JavaScript in between. A
slow reader skips to the newest; nothing queues.

| Writer (the backend) | |
|----------------------|-|
| `int rexui_frames_create(rexui_frames_writer *w, const char *name, uint32_t capacity)` | a region named `/rexui.<pid>.<what>` (31 bytes at most) of `capacity` floats a frame; 0, or -1 with `errno` |
| `float *rexui_frames_back(rexui_frames_writer *w)` | where the next frame goes |
| `void rexui_frames_publish(rexui_frames_writer *w, uint32_t count)` | the back buffer's first `count` floats become the newest frame |
| `void rexui_frames_close(rexui_frames_writer *w)` | unmaps and unlinks it |

Announce the region's name once, as a state key, and bind it to an element that reads frames (`Visualiser`, `Graph`,
`Canvas`, `Shader`):

```c
rexui_frames_writer w;
rexui_frames_create(&w, "/rexui.123.bars", 64);
const char *announce = "{\"frames\":\"/rexui.123.bars\"}";
rexui_state_json(announce, strlen(announce));
for (;;) { float *f = rexui_frames_back(&w); fill(f, 64); rexui_frames_publish(&w, 64); wait_for_audio(); }
```

```qml
Process { id: vis; command: ["mine-bars"] }
Visualiser { frames: vis.state.frames; width: 200; height: 200 }
```

rexui checks the region's sizes and indices before using it, copies each frame out and makes anything not finite 0.

## Where rexui finds a backend

A bare command name (`command: ["mine-clock"]`) is looked up in the distro's own built backends first, then the shown
distro's, then `~/.config/rex/backends/`, `~/.local/bin`, Homebrew, and the system's `PATH`. A relative path
(`./my-backend`) is next to the `.rui` file.

## In a distro, built by Bazel

A distro carries its backends as source. Its folder is a Bazel module (`MODULE.bazel`, and an empty `BUILD.bazel` at its
top) that depends on the `rexui` module, and each backend is a package `backends/<name>/` whose `BUILD.bazel` has a
binary target named as the command its `.rui` files run:

```starlark
# MODULE.bazel
module(name = "rexui_mine")

bazel_dep(name = "rexui", version = "1.0.0")
local_path_override(module_name = "rexui", path = "../..")   # where your rexui checkout is
bazel_dep(name = "apple_support", version = "2.11.0")
bazel_dep(name = "rules_swift", version = "4.2.2")
```

```starlark
# backends/clock/BUILD.bazel
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")

swift_binary(
    name = "mine-clock",                                                  # Process { command: ["mine-clock"] }
    srcs = ["main.swift", "@rexui//backends/sdk/swift:RexuiBackend.swift"],
)
```

`rexui build` (and `rexui load`, and Rex UI the first time it shows a distro whose backends changed) builds them with
`-c opt` into rexui's cache, by name; a running backend whose program changed restarts on it. The SDK files are taken by
label: `@rexui//backends/sdk/swift:RexuiBackend.swift` in a Swift target's `srcs`, `@rexui//backends/sdk/c:backend` (the C
header and `rexui_proto.h`) in a C one's `deps`, `@rexui//backends/sdk/rust:rexui.rs` copied beside a Rust `main.rs` by a
genrule; `@rexui//backends/include:frames` is `rexui_frames.h`. Zig and Odin backends keep a copy of the SDK file beside
their source. A backend outside a distro keeps a copy of its SDK file beside its source.
