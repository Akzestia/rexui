#!/usr/bin/env bash
# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: LicenseRef-rexui-1.0
set -uo pipefail

stamp=build/requirements.ok
fingerprint() {
    sw_vers -productVersion; uname -m; xcode-select -p 2>/dev/null; xcrun --show-sdk-version 2>/dev/null
    for t in just make bazel git; do command -v "$t" || echo "no $t"; done
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "/Applications/Rex Beta.app/Contents/Info.plist" 2>/dev/null
}
once=false
if [ "${1:-}" = --once ]; then
    once=true
    print=$(fingerprint)
    [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$print" ] && exit 0
fi

exec 3>&1
tty=false
[ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && tty=true
color=false
if [ -n "${FORCE_COLOR:-}" ] || { $tty && [ -z "${NO_COLOR:-}" ]; }; then color=true; fi
if $color; then
    G=$'\033[36m' Y=$'\033[33m' R=$'\033[31m' C=$'\033[36m' D=$'\033[2m' B=$'\033[1m' Z=$'\033[0m'
else
    G= Y= R= C= D= B= Z=
fi

total=$(grep -c '^step ' "$0") n=0 label=
oks=0 warns=0 fails=0
frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

rep() { local i s=; for ((i = 0; i < $1; i++)); do s+=$2; done; printf '%s' "$s"; }

bar() {
    $tty || return 0
    local w=24 done=$((n > 0 ? n - 1 : 0))
    local f=$((done * w / total))
    printf '\r\033[K  %s%s%s%s%s %s%d/%d%s %s %s%s%s' "$C" "$(rep $f █)" "$D" "$(rep $((w - f)) ░)" "$Z" \
        "$D" "$done" "$total" "$Z" "${1:-${frames[0]}}" "$D" "$label" "$Z" >&3
}
clear_bar() { $tty && printf '\r\033[K' >&3; return 0; }

step() { n=$((n + 1)); label=$1; bar; }
sections=0
section() {
    clear_bar
    [ $sections -eq 0 ] || echo
    sections=$((sections + 1))
    printf ' %s%s%s\n' "$B" "$1" "$Z"
    bar
}

result() {
    clear_bar
    printf '  %s%s%s %-12s %-18s %s%s%s\n' "$2" "$1" "$Z" "$3" "$4" "$D" "${5:-}" "$Z"
    bar
}
ok() { oks=$((oks + 1)); result ✓ "$G" "$@"; }
warn() { warns=$((warns + 1)); result ! "$Y" "$@"; }
fail() { fails=$((fails + 1)); result ✗ "$R" "$@"; }

spin() {
    if ! $tty; then "$@"; return; fi
    "$@" &
    local pid=$! i=0
    while kill -0 $pid 2>/dev/null; do
        bar "$C${frames[i % 10]}$Z"
        i=$((i + 1))
        sleep 0.08
    done
    wait $pid
}

ge() {
    local IFS=.
    local i a=($1) b=($2)
    for ((i = 0; i < ${#b[@]} || i < ${#a[@]}; i++)); do
        local x=${a[i]:-0} y=${b[i]:-0}
        x=${x%%[!0-9]*} y=${y%%[!0-9]*}
        ((10#${x:-0} > 10#${y:-0})) && return 0
        ((10#${x:-0} < 10#${y:-0})) && return 1
    done
    return 0
}
need() {
    if [ -z "$2" ]; then fail "$1" "not found" "need ≥ $3 · $4"
    elif ge "$2" "$3"; then ok "$1" "$2" "≥ $3"
    else fail "$1" "$2" "need ≥ $3 · $4"; fi
}
num() { grep -oE '[0-9]+(\.[0-9]+)+|[0-9]+' | head -1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rexui-req.XXXXXX")
trap 'clear_bar; rm -rf "$tmp"' EXIT
trap 'exit 130' INT

section system
step macOS
need macOS "$(sw_vers -productVersion 2>/dev/null)" 26.0 "rexui.dylib is built for macOS 26"
step arch
arch=$(uname -m)
if [ "$arch" = arm64 ]; then ok arch arm64 "Apple silicon"
else fail arch "$arch" "rexui is built for Apple silicon (arm64) only"; fi
step cpu
cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
gen=$(echo "$cpu" | sed -nE 's/^Apple M([0-9]+).*/\1/p')
if [ -n "$gen" ]; then ok cpu "$cpu" "the release build's -mcpu=apple-m1 runs on M1 and later"
else warn cpu "${cpu:-unknown}" "not an Apple M chip: the release build is -mcpu=apple-m1"; fi

step Rex
rex="/Applications/Rex Beta.app"
if [ -d "$rex" ]; then
    build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$rex/Contents/Info.plist" 2>/dev/null)
    supported=$(grep -vE '^\s*(#|$)' src/rex/supported.txt 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')
    if [[ " $supported " == *" $build "* ]]; then ok Rex "build $build" "supported"
    else warn Rex "build $build" "supported: ${supported:-unknown}; another build may turn features off (rexui.log: rex deps)"; fi
else
    fail Rex "not found" "no $rex: rexui loads into a copy of your licensed Rex Beta"
fi

section build
step Xcode
dev=$(xcode-select -p 2>/dev/null)
xcode=$(spin xcodebuild -version 2>/dev/null | head -1 | num)
if [[ "$dev" != *.app/Contents/Developer ]]; then
    fail Xcode "${dev:-unset}" "not Xcode.app: install Xcode 26, then sudo xcode-select -s /Applications/Xcode.app"
else need Xcode "$xcode" 26.0 "the macOS 26 SDK, rules_swift under Bazel"; fi
step SDK
need SDK "$(xcrun --show-sdk-version 2>/dev/null)" 26.0 "the macOS 26 SDK (Xcode 26)"
step clang
need clang "$(xcrun clang++ --version 2>/dev/null | head -1 | sed -nE 's/.*clang version ([0-9.]+).*/\1/p')" 17 "Apple clang from Xcode 26"
step Swift
need Swift "$(spin xcrun swiftc --version 2>&1 | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -1)" 6.2 "src/rex, the Swift backends"

step "C++23 probe"
cat > "$tmp/probe.cc" <<'EOF'
#include <expected>
#include <flat_map>
int main() {
    std::flat_map<int, int> m{{1, 2}};
    std::expected<int, int> e = m.at(1);
    return e.value() == 2 ? 0 : 1;
}
EOF
if spin xcrun clang++ -std=c++23 -arch arm64 -mmacosx-version-min=26.0 -fno-exceptions -fno-rtti -o "$tmp/probe" "$tmp/probe.cc" 2>"$tmp/err" &&
    "$tmp/probe"; then
    ok C++23 "compiles" "<expected>, <flat_map>"
else
    fail C++23 "no" "the compiler lacks <expected>/<flat_map>: $(head -1 "$tmp/err")"
fi

step just
need just "$(just --version 2>/dev/null | num)" 1.33 "brew install just"
step make
need make "$(make --version 2>/dev/null | head -1 | num)" 3.81 "the system's (Xcode)"
step Bazel
if command -v bazel >/dev/null; then
    need Bazel "$(cd "${TMPDIR:-/tmp}" && spin bazel --version 2>/dev/null | num)" 9.0 "the backends, apps in panes (brew install bazelisk)"
else fail Bazel "not found" "need ≥ 9.0 · the backends, apps in panes (brew install bazelisk)"; fi
step git
need git "$(git --version 2>/dev/null | num)" 2.0 "git ls-files lists the files to check"

step "macOS tools"
missing=
for t in curl unzip codesign ditto sips iconutil defaults notifyutil osascript mdfind; do
    command -v "$t" >/dev/null || missing+=" $t"
done
for t in /usr/libexec/PlistBuddy /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; do
    [ -x "$t" ] || missing+=" $(basename "$t")"
done
if [ -z "$missing" ]; then ok "macOS tools" "all 12" "curl unzip codesign ditto PlistBuddy lsregister sips ..."
else fail "macOS tools" "missing:$missing" "they ship with macOS"; fi

section optional
step browser
zen="$HOME/Library/Application Support/zen/Profiles" ff="$HOME/Library/Application Support/Firefox/Profiles"
if [ -n "$(ls -A "$zen" 2>/dev/null)" ]; then ok browser "Zen" "the web docks' logins"
elif [ -n "$(ls -A "$ff" 2>/dev/null)" ]; then ok browser "Firefox" "the web docks' logins"
else warn browser "no profile" "no Zen or Firefox profile: the web docks start logged out"; fi
step "Claude Code"
if PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin" command -v claude >/dev/null; then ok "Claude Code" "claude" "Ask's agents"
else warn "Claude Code" "not found" "Ask (README: Agents) is off"; fi
step CrossOver
if [ -d "/Applications/CrossOver.app" ] || [ -d "$HOME/Applications/CrossOver.app" ]; then ok CrossOver "installed" "Windows programs in panes"
else warn CrossOver "not installed" "only for Windows programs in panes (rexui embed)"; fi

n=$((total + 1))
clear_bar
all=$((oks + warns + fails)) w=32
y=$((warns * w / all)) r=$((fails * w / all))
[ $warns -gt 0 ] && [ $y -eq 0 ] && y=1
[ $fails -gt 0 ] && [ $r -eq 0 ] && r=1
g=$((w - y - r))
printf '\n  %s%s%s%s%s%s%s%s%s  %s%d ok%s · %s%d warn%s · %s%d missing%s\n' \
    "$G" "$(rep $g █)" "$Z" "$Y" "$(rep $y ▓)" "$Z" "$R" "$(rep $r ░)" "$Z" \
    "$G" $oks "$Z" "$Y" $warns "$Z" "$R" $fails "$Z"
if [ $fails -gt 0 ]; then
    printf '  %s%s%d required %s missing%s (each line says how to get it)\n' "$R" "$B" $fails "$([ $fails = 1 ] && echo is || echo are)" "$Z"
    exit 1
fi
printf '  %s%severything required is here%s\n' "$G" "$B" "$Z"
if $once; then mkdir -p "$(dirname "$stamp")" && echo "$print" > "$stamp"; fi
