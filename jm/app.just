set working-directory := '../'

rex := "/Applications/Rex Beta.app"
app := env("HOME") / "Applications/Rex UI.app"
build := justfile_directory() / ".." / "build"

[doc("~/Applications/Rex UI.app: an ad-hoc re-signed copy of Rex that loads build/rexui.dylib (Rex itself is untouched). Again after every Rex update")]
install:
    #!/usr/bin/env bash
    set -euo pipefail
    build=$(cd build && pwd)
    rm -rf "{{app}}"
    ditto "{{rex}}" "{{app}}"
    plist="{{app}}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy \
        -c "Add :LSEnvironment dict" \
        -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $build/rexui.dylib" \
        -c "Add :LSEnvironment:REXUI_HOME string $build" \
        -c "Add :LSEnvironment:REX_TRANSPARENT_DUMP string ${REX_TRANSPARENT_DUMP:-0}" \
        "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Rex UI" -c "Set :CFBundleDisplayName Rex UI" "$plist"
    if [ -f build/AppIcon.icns ]; then
        cp build/AppIcon.icns "{{app}}/Contents/Resources/rexui.icns"
        /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" -c "Set :CFBundleIconFile rexui" "$plist" 2>/dev/null || true
    fi
    codesign --force --deep --sign - "{{app}}"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "{{app}}"
    mdimport "{{app}}" 2>/dev/null || true
    echo "installed {{app}}"

[doc("Rex UI.app's icon in Finder, Launchpad and Spotlight: a picture (PNG, JPEG, ICNS; square, 1024 px best), or \"rex\" for Rex's own. Kept for every just app::install. The Dock's while it runs is rui-config.lua's app_icon")]
icon picture:
    #!/usr/bin/env bash
    set -euo pipefail
    plist="{{app}}/Contents/Info.plist"
    if pgrep -qf "Rex UI.app/Contents/MacOS/"; then echo "icon: quit Rex UI first (just app::quit)"; exit 1; fi
    if [ "{{picture}}" = rex ]; then
        rm -f build/AppIcon.icns "{{app}}/Contents/Resources/rexui.icns"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile 'App Icon Beta'" -c "Add :CFBundleIconName string 'App Icon Beta'" "$plist" 2>/dev/null || true
    else
        src=$(cd "$(dirname "{{picture}}")" && pwd)/$(basename "{{picture}}")
        mkdir -p build
        case "$src" in
        *.icns) cp "$src" build/AppIcon.icns ;;
        *)
            set=$(mktemp -d)/rexui.iconset
            mkdir -p "$set"
            for s in 16 32 128 256 512; do
                sips -s format png -z $s $s "$src" --out "$set/icon_${s}x${s}.png" >/dev/null
                sips -s format png -z $((s * 2)) $((s * 2)) "$src" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
            done
            iconutil -c icns "$set" -o build/AppIcon.icns
            rm -rf "$(dirname "$set")" ;;
        esac
        cp build/AppIcon.icns "{{app}}/Contents/Resources/rexui.icns"
        /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" -c "Set :CFBundleIconFile rexui" "$plist" 2>/dev/null || true
    fi
    codesign --force --deep --sign - "{{app}}"
    touch "{{app}}"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "{{app}}"
    echo "icon: {{picture}} (the Dock follows at the next launch, or at once with app_icon)"

[doc("Start Rex UI (through LaunchServices: the environment only applies that way)")]
launch:
    open -a "{{app}}"

[doc("Quit Rex UI (Rex Server keeps the sessions)")]
quit:
    -osascript -e 'tell application "{{app}}" to quit'

[doc("Quit, start again, and give the keyboard back to Ghostty")]
relaunch:
    -osascript -e 'tell application "{{app}}" to quit'
    for i in $(seq 50); do pgrep -qf "Rex UI.app/Contents/MacOS/" || break; sleep 0.1; done
    for i in $(seq 25); do open -a "{{app}}" 2>/dev/null && exit 0; sleep 0.2; done; open -a "{{app}}"
    sleep 1
    -osascript -e 'tell application "Ghostty" to activate'

[doc("Follow ~/Library/Logs/rexui.log")]
log:
    tail -f ~/Library/Logs/rexui.log
