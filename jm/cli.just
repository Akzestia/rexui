set working-directory := '../'

bin := env("HOME") / ".local/bin"
lua := env("HOME") / ".config/rex/lua"

[doc("Link rexui into ~/.local/bin, rexui.lua into ~/.config/rex/lua and its zsh completion onto $fpath (never over a file of someone else's)")]
install:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{bin}}" "{{lua}}" "$HOME/.config/rex/distros"
    for pair in "src/cli/rexui:{{bin}}/rexui" "src/cli/rexui.lua:{{lua}}/rexui.lua"; do
        from="$PWD/${pair%%:*}" to="${pair#*:}"
        if [ -L "$to" ] || [ ! -e "$to" ]; then ln -sf "$from" "$to"; else echo "$to is someone else's: left as it is"; fi
    done
    echo "rexui: $(command -v rexui || echo '{{bin}}/rexui (not on PATH)')"
    zdir="$HOME/.oh-my-zsh/custom/completions"
    [ -d "$HOME/.oh-my-zsh" ] || zdir="$HOME/.zfunc"
    mkdir -p "$zdir"
    if [ -L "$zdir/_rexui" ] || [ ! -e "$zdir/_rexui" ]; then
        ln -sf "$PWD/src/cli/completions/_rexui" "$zdir/_rexui"
        echo "zsh completion: $zdir/_rexui (a new shell: exec zsh; still none: rm ~/.zcompdump* first)"
    else echo "$zdir/_rexui is someone else's: left as it is"; fi

[doc("Every distro as ~/.config/rex/distros/<name> (a link: rexui load <name> shows this checkout's), but shared (the distros' shared files, use \"rexshared\") and vanilla (rexui default)")]
examples:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.config/rex/distros
    for src in distros/*/; do
        name=$(basename "$src")
        case $name in shared | vanilla) continue ;; esac
        d=~/.config/rex/distros/$name
        if [ -L "$d" ] || [ ! -e "$d" ]; then ln -sfn "$PWD/distros/$name" "$d"; else echo "$d is someone else's: left as it is"; fi
    done
