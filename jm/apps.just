set working-directory := '../'

bin := env("HOME") / ".local/bin"

[doc("rexui's own apps (build/apps) and the main distro's (and backends: rexui build), linked into ~/.local/bin")]
install: core
    #!/usr/bin/env bash
    set -euo pipefail
    src/cli/rexui build distros/main
    p=$(cd distros/main && pwd -P); p=${p#/}
    built="$HOME/Library/Caches/rexui/distros/${p//\//%}/bin"
    mkdir -p "{{bin}}"
    for n in $(sed -n 's/^ *name = "\(rexui-[^"]*\)".*/\1/p' distros/main/panes/*/BUILD.bazel); do
        to="{{bin}}/$n"
        if [ -L "$to" ] || [ ! -e "$to" ]; then ln -sfn "$built/$n" "$to"; fi
    done

[doc("The apps linked in ~/.local/bin")]
list:
    ls -l "{{bin}}"/rexui-*

[doc("rexui's own apps (rexui-embed and its library, universal: CrossOver's Wine is x86_64; rexui-pane) into build/apps, for rexui embed, pane and launch")]
core:
    #!/usr/bin/env bash
    set -euo pipefail
    bazel build -c opt //apps/embed:rexui-embed //apps/pane:rexui-pane
    files() { bazel cquery -c opt --output=files "$1" 2>/dev/null; }
    mkdir -p build/apps "{{bin}}"
    install -m 0755 apps/embed/rexui-embed.sh build/apps/rexui-embed
    install -m 0755 "$(files //apps/embed:librexui-embed.dylib)" build/apps/librexui-embed.dylib
    install -m 0755 "$(files //apps/pane:rexui-pane)" build/apps/rexui-pane
    for n in rexui-embed rexui-pane; do
        to="{{bin}}/$n"
        if [ -L "$to" ]; then case $(readlink "$to") in */build/apps/$n | */bin/$n) rm "$to"; echo "removed $to (rexui ${n#rexui-} now)" ;; esac; fi
    done
    ls -l build/apps
