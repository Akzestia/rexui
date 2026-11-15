#!/usr/bin/env bash
# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: MIT
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

fetch() {
    local dir=$1 name=$2 url=$3 blob=$4
    mkdir -p "$dir"
    local out="$dir/$name"
    if [ -f "$out" ] && [ "$(git hash-object "$out")" = "$blob" ]; then echo "  $name: there"; return; fi
    curl -fsSL --retry 2 -A "rexui-fonts" -o "$out.part" "$url"
    if [ "$(git hash-object "$out.part")" != "$blob" ]; then rm -f "$out.part"; echo "fetch: $name: not the file expected" >&2; exit 1; fi
    mv "$out.part" "$out"
    echo "  $name ($(($(stat -f %z "$out") / 1024)) KB)"
}

echo "HarmonyOS Sans"
hos=https://raw.githubusercontent.com/openharmony/resources/58f1bfa287d8664b0d12ecfd73666773fe820a66/fonts
fetch HarmonyOS HarmonyOS_Sans_Regular.ttf "$hos/HarmonyOS_Sans_Regular.ttf" d7eccac8ee2259a042d7434fbf65dfe398265b24
fetch HarmonyOS HarmonyOS_Sans_Medium.ttf "$hos/HarmonyOS_Sans_Medium.ttf" 9bcfaa122a44f53734e4c88c7dea7fd469b6ed65
fetch HarmonyOS HarmonyOS_Sans_Bold.ttf "$hos/HarmonyOS_Sans_Bold.ttf" 8ea60c10b6cf32108b7acff6343f88f7889f815c
fetch HarmonyOS HarmonyOS_Sans_Light.ttf "$hos/HarmonyOS_Sans_Light.ttf" 9b6778571b9d9d189fe0bef9c7751c0581a6a276

echo "Saira, Space Grotesk"
fetch Saira 'Saira[wdth,wght].ttf' 'https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/saira/Saira%5Bwdth,wght%5D.ttf' b7e017b39f1b3b82daeeccbd21c6c1f1cc3965b5
fetch SpaceGrotesk 'SpaceGrotesk[wght].ttf' 'https://raw.githubusercontent.com/google/fonts/00a38a53f92aef923b9353f40128e8f4552ddae4/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf' a1b2e6c26093066510a31147e7aec9abdc8d6c5e

echo "Iosevka"
mkdir -p Iosevka
want=(Iosevka-Regular.ttf Iosevka-Medium.ttf Iosevka-Bold.ttf)
sizes=(11613712 11602640 11679068)
missing=()
for i in "${!want[@]}"; do
    f=Iosevka/${want[$i]}
    if [ -f "$f" ] && [ "$(stat -f %z "$f")" = "${sizes[$i]}" ]; then echo "  ${want[$i]}: there"; else missing+=("${want[$i]}"); fi
done
if [ ${#missing[@]} -gt 0 ]; then
    python3 -I "$here/zipget.py" https://github.com/be5invis/Iosevka/releases/download/v34.9.1/PkgTTF-Iosevka-34.9.1.zip \
        "${missing[@]}" --into "$here/Iosevka"
    for i in "${!want[@]}"; do
        f=Iosevka/${want[$i]}
        [ "$(stat -f %z "$f")" = "${sizes[$i]}" ] || { echo "fetch: ${want[$i]}: not the size expected" >&2; exit 1; }
    done
fi
echo "done: rexui registers them the next time it reads the distro (a save of any of its files, or rexui load endfield)."
