set working-directory := '../'

build := "build"
lib := build / "rexui.dylib"
frameworks := "-lcompression -framework AppKit -framework QuartzCore -framework Metal -framework ImageIO -framework CoreText -framework WebKit -framework UniformTypeIdentifiers -framework AVFoundation -framework UserNotifications -framework CoreMedia -framework IOKit -framework QuickLookThumbnailing -framework GameController -framework IOSurface -lsqlite3 -licucore"
flags := "-std=c++23 -fobjc-arc -arch arm64 -Wall -Wextra -Wshadow -Warc-repeated-use-of-weak -Wno-unused-parameter -Wno-missing-field-initializers -Werror -I src -I backends/include -I third_party -I " + build
swift := "xcrun swiftc -O -wmo -parse-as-library -module-name RexUIRex -target arm64-apple-macos15 -import-objc-header src/rex/bridge.h -I src"

[doc("The library: every src/**/*.mm, src/**/*.cc and src/rex/*.swift, ad-hoc signed; rexui-check and rui-ls beside it; only what changed, in parallel (jm/dylib.mk)")]
dylib: requirements
    @mkdir -p {{build}}
    make -s -f jm/dylib.mk -j "$(sysctl -n hw.ncpu)" FLAGS='{{flags}}' FRAMEWORKS='{{frameworks}}' SWIFT='{{swift}}'

[doc("The release library (just install's): -O3 for every Apple silicon Mac (-mcpu=apple-m1: M1 and later), full LTO (build/release); copied over build/rexui.dylib, which Rex UI loads")]
release: requirements
    #!/usr/bin/env bash
    set -euo pipefail
    just build::dylib >/dev/null
    opt='-O3 -mcpu=apple-m1 -flto=full'
    mkdir -p build/release
    if [ "$(cat build/release/flags 2>/dev/null)" != "$opt" ]; then rm -rf build/release/obj build/release/rexui.dylib; echo "$opt" > build/release/flags; fi
    make -s -f jm/dylib.mk -j "$(sysctl -n hw.ncpu)" B=build/release FLAGS='{{flags}}' FRAMEWORKS='{{frameworks}}' SWIFT='{{swift}}' \
        OPT="$opt" build/release/rexui.dylib
    cp build/release/rexui.dylib build/rexui.dylib.new
    mv build/rexui.dylib.new build/rexui.dylib
    echo "build/rexui.dylib: release (-O3, apple-m1, full LTO)"

[private]
requirements:
    @bash src/cli/requirements.sh --once

[doc("Compile every file without linking (fast; for editing)")]
check:
    make -s -f jm/dylib.mk gen
    xcrun clang++ {{flags}} -fsyntax-only $(find src -name '*.mm' -not -path 'src/rex/stub/*' | sort)
    {{swift}} -typecheck src/rex/*.swift {{build}}/gen/rx_names.swift

[doc("compile_commands.json for clangd")]
cc:
    #!/usr/bin/env bash
    set -euo pipefail
    {
        echo '['
        first=1
        for f in $(find src -name '*.mm' | sort); do
            [ $first = 1 ] || echo ','
            first=0
            printf '{"directory": "%s", "file": "%s", "command": "clang++ -x objective-c++ %s -c %s"}' \
                "$PWD" "$f" "{{flags}}" "$f"
        done
        echo ']'
    } > compile_commands.json

[doc("clang's static analyzer over everything the library compiles: any report fails")]
analyze:
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(mktemp)
    for f in $(find src -name '*.mm' -not -path 'src/rex/stub/*'); do
        xcrun clang++ --analyze -std=c++23 -fobjc-arc -arch arm64 -I src -I backends/include -I third_party -I {{build}} -I {{build}}/gen -Xanalyzer -analyzer-output=text -o /dev/null "$f" 2>&1 | grep ': warning:' >> "$out" || true &
        while [ "$(jobs -r | wc -l)" -ge 8 ]; do sleep 0.1; done
    done
    for f in $(find src -name '*.cc'); do
        xcrun clang++ --analyze -std=c++23 -arch arm64 -I src -I backends/include -I {{build}} -Xanalyzer -analyzer-output=text -o /dev/null "$f" 2>&1 | grep ': warning:' >> "$out" || true &
        while [ "$(jobs -r | wc -l)" -ge 8 ]; do sleep 0.1; done
    done
    wait
    n=$(sort -u "$out" | wc -l | tr -d ' ')
    sort -u "$out"
    rm -f "$out"
    [ "$n" = 0 ] && echo "analyzer: clean" || { echo "analyzer: $n reports"; exit 1; }
