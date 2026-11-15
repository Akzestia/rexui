#!/usr/bin/env bash
# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: LicenseRef-rexui-1.0
set -euo pipefail
die() { echo "rexui embed: $*" >&2; exit 2; }
[ "${1:-}" = --relative ] && { export REXUI_EMBED_RELATIVE=1; shift; }
cx=""
[ "${1:-}" = --crossover ] && { cx=1; shift; }
[ $# -ge 1 ] || die "usage: rexui embed [--relative] [--crossover] <app name, path or program | bottle [program]> [args...]"
[ -n "${REX_BLOCK:-}" ] || die "not in a Rex pane (\$REX_BLOCK unset)"

self=$(readlink -f "$0" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
lib="$(dirname "$self")/librexui-embed.dylib"
[ -f "$lib" ] || die "no $lib (rexui build: it's installed beside this script)"

want=$1; shift
if printf '%s\n' "$@" | grep -q '{pane_[wh]}'; then
    prev=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.4
        size=$(stty size 2>/dev/null)
        [ -n "$size" ] && [ "$size" != "24 80" ] && [ "$size" = "$prev" ] && break
        prev=$size
    done
    read -r pane_w pane_h < <(python3 -c 'import fcntl,struct,sys,termios
r = fcntl.ioctl(sys.stdin.fileno(), termios.TIOCGWINSZ, bytes(8)); _, _, x, y = struct.unpack("HHHH", r); print(x, y)')
    if [ "${pane_w:-0}" -eq 0 ]; then
        rex_cli=/Applications/Rex\ Beta.app/Contents/Helpers/Rex\ Server.rex/Contents/MacOS/rex
        read -r pane_w pane_h < <("$rex_cli" api call ${REX_SESSION:+-s "$REX_SESSION"} block.method \
            "{\"block_id\":\"$REX_BLOCK\",\"method\":\"size\"}" 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin); print(d["columns"] * d["cell_width_px"], d["rows"] * d["cell_height_px"])' 2>/dev/null)
    fi
    [ "${pane_w:-0}" -gt 0 ] || die "the pane's size in pixels is unknown"
    args=()
    for a in "$@"; do a=${a//\{pane_w\}/$pane_w}; args+=("${a//\{pane_h\}/$pane_h}"); done
    set -- "${args[@]}"
fi
export REXUI_EMBED_PID=$$
base="$HOME/Library/Application Support/rexui/embed"

crossover() {
    local bottle=$1 name=$2; shift 2
    [ -d "$HOME/Library/Application Support/CrossOver/Bottles/$bottle" ] || die "no CrossOver bottle named $bottle"
    local src=${REXUI_CROSSOVER:-/Applications/CrossOver.app}
    [ -n "${REXUI_CROSSOVER:-}" ] && { [ -d "$src" ] || die "no CrossOver at \$REXUI_CROSSOVER ($src)"; }
    [ -d "$src" ] || src=$(mdfind "kMDItemCFBundleIdentifier == 'com.codeweavers.CrossOver'" 2>/dev/null | grep -v "^$base/" | head -1)
    [ -n "$src" ] && [ -d "$src" ] || die "CrossOver isn't installed"
    lipo -archs "$lib" 2>/dev/null | grep -q x86_64 || die "$lib has no x86_64 (just apps::install builds it universal)"
    local info="$src/Contents/Info.plist" copy="$base/$(basename "$src")"
    local stamp; stamp="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info" 2>/dev/null || echo 0) $(stat -f %m "$info")"
    stamp="$stamp $(stat -f %m "$src/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/ntdll.so" 2>/dev/null || echo 0)"
    mkdir -p "$base"
    if [ ! -f "$copy/.rexui-stamp" ] || [ "$(cat "$copy/.rexui-stamp")" != "$stamp" ]; then
        echo "rexui embed: preparing a copy of $(basename "$src" .app)…"
        rm -rf "$copy"
        cp -Rc "$src" "$copy" || { rm -rf "$copy"; die "couldn't clone $src (not on the same APFS volume as $base?)"; }
        xattr -cr "$copy" 2>/dev/null || true
        rm -rf "$copy/Contents/Frameworks/Sparkle.framework/Versions/"*/Autoupdate* "$copy/Contents/Frameworks/Sparkle.framework/Versions/"*/Updater.app
        find "$copy" -type f -perm +111 -print0 | while IFS= read -r -d '' f; do
            case "$(file -b "$f")" in *Mach-O*) codesign --force --sign - "$f" >/dev/null 2>&1 || die "couldn't re-sign $f";; esac
        done
        echo "$stamp" > "$copy/.rexui-stamp"
    fi
    export DYLD_INSERT_LIBRARIES="$lib" REXUI_EMBED_WINE=1 REXUI_EMBED_NAME="$name"
    export REXUI_EMBED_LOCK="${TMPDIR:-/tmp/}rexui-embed-${REX_BLOCK//[^A-Za-z0-9_-]/_}.lock"
    unset REXUI_EMBED_PID
    local debug=()
    [ -n "${REXUI_WINE_DEBUG:-}" ] && debug=(--debugmsg "$REXUI_WINE_DEBUG" --cx-log "$HOME/Library/Logs/rexui-wine.log")
    exec "$copy/Contents/SharedSupport/CrossOver/bin/wine" --bottle "$bottle" ${debug[@]+"${debug[@]}"} --wait-children "$@"
}

launcher() {
    local app=$1; shift
    local info="$app/Contents/Info.plist" bottle cmd
    bottle=$(/usr/libexec/PlistBuddy -c "Print :CXHelperAppBottleName" "$info" 2>/dev/null) || die "$app isn't a CrossOver launcher"
    cmd=$(/usr/libexec/PlistBuddy -c "Print :CrossOverHelperCommand" "$info" 2>/dev/null || true)
    [ -n "$cmd" ] || die "$app names no program"
    local parts=() args=()
    while IFS= read -r -d '' p; do parts+=("$p"); done < <(python3 -c 'import shlex,sys; sys.stdout.write("".join(a+"\0" for a in shlex.split(sys.argv[1])))' "$cmd")
    [ ${#parts[@]} -ge 1 ] || die "$app names no program"
    while IFS= read -r -d '' p; do args+=("$p"); done < <(python3 - "${parts[0]}" <<'PY'
import shlex, sys
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    sys.exit()
for l in lines:
    l = l.strip()
    if not l.startswith("exec "):
        continue
    a = shlex.split(l)[1:]
    if not a or not a[0].endswith("/bin/wine"):
        continue
    out, i = [], 1
    while i < len(a):
        if a[i] == "--bottle":
            i += 2
            continue
        if a[i] not in ('"$@"', "$@"):
            out.append(a[i])
        i += 1
    sys.stdout.write("".join(x + "\0" for x in out))
    break
PY
)
    if [ ${#args[@]} -gt 0 ]; then
        crossover "$bottle" "$(basename "$app" .app)" "${args[@]}" "${parts[@]:1}" "$@"
    fi
    crossover "$bottle" "$(basename "$app" .app)" --start "${parts[0]}" "${parts[@]:1}" "$@"
}

if [ -n "$cx" ]; then
    if [ -d "$want" ] && [ -f "$want/Contents/Info.plist" ]; then launcher "$want" "$@"; fi
    if [ $# -eq 0 ] || [ ! -d "$HOME/Library/Application Support/CrossOver/Bottles/$want" ]; then
        for a in "$HOME/Applications/CrossOver/"*/"$want.app"; do [ -d "$a" ] && launcher "$a" "$@"; done
    fi
    [ $# -ge 1 ] || die "name a program to run in the bottle $want (a .lnk, an .exe's path, or its name: steam.exe)"
    prog=$1; shift
    named=$(basename "${prog//\\//}" | sed 's/\.[^.]*$//')
    case "$prog" in [A-Za-z]:\\*|[A-Za-z]:/*)
        rest=${prog:2}; rest=${rest//\\//}
        unix="$HOME/Library/Application Support/CrossOver/Bottles/$want/dosdevices/$(printf %s "${prog:0:1}" | tr A-Z a-z):$rest"
        [ -e "$unix" ] && prog=$unix;;
    esac
    case "$prog" in
        *.lnk|*.LNK|*.url|*.URL) crossover "$want" "$named" --start "$prog" "$@";;
        /*|./*|../*|[A-Za-z]:\\*|[A-Za-z]:/*) crossover "$want" "$named" "$prog" "$@";;
        *)
            win="$HOME/Library/Application Support/CrossOver/Bottles/$want/drive_c/windows"
            for d in "$win/system32" "$win"; do [ -f "$d/$prog" ] && crossover "$want" "$named" "$d/$prog" "$@"; done
            crossover "$want" "$named" --cx-app "$prog" "$@";;
    esac
fi
export SDL_MOUSE_FOCUS_CLICKTHROUGH=1
export SDL_VIDEO_MAC_FULLSCREEN_SPACES=0

case "$want" in *.app|*.app/) ;; *)
    prog=""
    if [ -f "$want" ] && [ -x "$want" ]; then prog=$want
    elif [ ! -d "$want" ]; then prog=$(command -v -- "$want" 2>/dev/null || true); fi
    if [ -n "$prog" ] && [ -f "$prog" ]; then
        codesign -dv "$prog" 2>&1 | grep -q 'flags=.*runtime' && die "$prog is signed with the hardened runtime (it can't load the library)"
        export DYLD_INSERT_LIBRARIES="$lib"
        exec "$prog" "$@"
    fi;;
esac

if [ -d "$want" ]; then
    src=$(cd "$want" && pwd)
else
    src=""
    for d in /Applications ~/Applications /Applications/Utilities; do
        [ -d "$d/$want.app" ] && { src="$d/$want.app"; break; }
    done
    if [ -z "$src" ]; then
        for a in "$HOME/Applications/CrossOver/"*/"$want.app"; do [ -d "$a" ] && { src=$a; break; }; done
    fi
    [ -n "$src" ] || src=$(mdfind "kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '$want'" 2>/dev/null | head -1)
    [ -n "$src" ] || die "no app named $want"
fi
case "$(cd "$src" && pwd -P)" in /System/* | /private/var/run/com.apple.*) die "$src is a system app (it can't be re-signed)";; esac

info="$src/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CXHelperAppBottleName" "$info" >/dev/null 2>&1 && launcher "$src" "$@"
exe_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info")
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info" 2>/dev/null || echo 0)
stamp="$version $(stat -f %m "$info") ui"
copy="$base/$(basename "$src")"
mkdir -p "$base"
if [ ! -f "$copy/.rexui-stamp" ] || [ "$(cat "$copy/.rexui-stamp")" != "$stamp" ]; then
    echo "rexui embed: preparing a copy of $(basename "$src")…"
    rm -rf "$copy"
    cp -Rc "$src" "$copy" || { rm -rf "$copy"; die "couldn't clone $src (not on the same APFS volume as $base?)"; }
    xattr -cr "$copy" 2>/dev/null || true
    rm -f "$copy/Contents/MacOS/UpdateMac" "$copy/Contents/MacOS/Update"
    rm -rf "$copy/Contents/Frameworks/Sparkle.framework/Versions/"*/Autoupdate* "$copy/Contents/Frameworks/Sparkle.framework/Versions/"*/Updater.app
    rm -f "$copy/Contents/Frameworks/Squirrel.framework/Versions/"*/Resources/ShipIt
    plutil -replace LSUIElement -bool YES "$copy/Contents/Info.plist" || die "couldn't mark the copy of $src as a background app"
    codesign --force --deep --sign - "$copy" >/dev/null 2>&1 || die "couldn't re-sign the copy of $src"
    echo "$stamp" > "$copy/.rexui-stamp"
fi

export DYLD_INSERT_LIBRARIES="$lib"
exec "$copy/Contents/MacOS/$exe_name" "$@"
