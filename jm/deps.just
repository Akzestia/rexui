set working-directory := '../'

build := "build"

[doc("Everything fetched: fonts, block lists, uBlock Origin Lite, dock icons, the main distro's pictures, each distro's own")]
all: fonts lists ubol icons media distros

[doc("Each distro's own downloads, what it needs that isn't in git: its fetch.sh at its top, run when it has one (endfield's: its four open fonts; its game marks stay opt-in, assets/marks.sh)")]
distros:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in distros/*/fetch.sh; do [ -f "$f" ] || continue; echo "${f%/fetch.sh}"; bash "$f"; done

[doc("Google Sans Flex, Rubik, Material Symbols Rounded (open licences) into build/fonts, loaded only inside Rex")]
fonts:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{build}}/fonts
    get() { [ -s "{{build}}/fonts/$1" ] || curl -fsSL --max-time 120 -o "{{build}}/fonts/$1" "$2"; }
    get GoogleSansFlex.ttf 'https://raw.githubusercontent.com/google/fonts/main/ofl/googlesansflex/GoogleSansFlex%5BROND%2Copsz%2Cslnt%2Cwdth%2Cwght%5D.ttf'
    get Rubik.ttf 'https://raw.githubusercontent.com/google/fonts/main/ofl/rubik/Rubik%5Bwght%5D.ttf'
    get MaterialSymbolsRounded.ttf 'https://github.com/google/material-design-icons/raw/master/variablefont/MaterialSymbolsRounded%5BFILL,GRAD,opsz,wght%5D.ttf'

[doc("The ad blocker lists, refreshed weekly: EasyList, EasyPrivacy, Peter Lowe's servers")]
lists:
    #!/usr/bin/env bash
    set -euo pipefail
    fetch() {
        if [ -z "$(find "{{build}}/$1" -mtime -7 2>/dev/null)" ]; then
            curl -fsSL --max-time 60 -o "{{build}}/$1.new" "$2" && mv "{{build}}/$1.new" "{{build}}/$1" ||
                echo "could not fetch $1; keeping the old one"
        fi
    }
    fetch easylist.txt https://easylist.to/easylist/easylist.txt
    fetch easyprivacy.txt https://easylist.to/easylist/easyprivacy.txt
    fetch adblock.txt 'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=nohtml&showintro=0&mimetype=plaintext'

[doc("uBlock Origin Lite's Safari build, checked weekly: build/ubol/<version>, build/ubol/current")]
ubol:
    #!/usr/bin/env bash
    set -euo pipefail
    b={{build}}/ubol
    [ -z "$(find "$b/checked" -mtime -7 2>/dev/null)" ] || exit 0
    mkdir -p "$b"
    url=$(curl -fsSL --max-time 30 https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest |
        grep -oE '"browser_download_url": *"[^"]*\.safari\.zip"' | sed 's/.*"\(https[^"]*\)"/\1/') || url=
    ver=$(echo "$url" | sed -n 's|.*/download/\([^/]*\)/.*|\1|p')
    if [ -n "$ver" ] && [ ! -f "$b/$ver/manifest.json" ]; then
        tmp=$(mktemp -d "$b/dl.XXXXXX")
        if curl -fsSL --max-time 180 -o "$tmp/ubol.zip" "$url" && mkdir "$tmp/x" && unzip -q "$tmp/ubol.zip" -d "$tmp/x" &&
            [ -f "$tmp/x/manifest.json" ]; then
            rm -rf "$b/$ver" && mv "$tmp/x" "$b/$ver"
        else
            echo "could not fetch uBlock Origin Lite $ver"
        fi
        rm -rf "$tmp"
    fi
    if [ -n "$ver" ] && [ -f "$b/$ver/manifest.json" ]; then
        ln -sfn "$ver" "$b/current"
        touch "$b/checked"
    fi

[doc("Dock icons that aren't SF Symbols or favicons (the main distro's ui/icons, checked in: deno.rui's) into ~/.config/rex/ui/icons")]
icons:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.config/rex/ui/icons
    for png in distros/main/ui/icons/*.png; do
        [ -f ~/.config/rex/ui/icons/"$(basename "$png")" ] || cp "$png" ~/.config/rex/ui/icons/
    done

[doc("The main distro's pictures that aren't rexui's: Bongo Cat (StrayRogue's drawing) for clock.rui's player, from Caelestia's repo")]
media:
    #!/usr/bin/env bash
    set -euo pipefail
    dir=distros/main/ui/assets
    get() {
        [ -s "$dir/$1" ] && return 0
        mkdir -p "$dir"
        if curl -fsSL --max-time 60 -o "$dir/$1.part" "$3" && [ "$(shasum -a 256 "$dir/$1.part" | cut -d' ' -f1)" = "$2" ]; then
            mv "$dir/$1.part" "$dir/$1"
        else
            rm -f "$dir/$1.part"
            echo "could not fetch $1; the main distro works without it"
        fi
    }
    get bongocat.gif 1fba455dbbf57507f8021fa49ce7ebb1d4a6973f0f1b5a760ad60e473befddf4 \
        https://raw.githubusercontent.com/caelestia-dots/shell/8326407e24d2850964da4597e9be80b6f5887f7b/assets/bongocat.gif
