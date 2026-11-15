set working-directory := '../'

[doc("Build every distro's backends and native panes (Bazel: rexui build each; one without a MODULE.bazel has none)")]
install:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in distros/*/; do src/cli/rexui build "${d%/}"; done

[doc("Every distro's built backends")]
list:
    #!/usr/bin/env bash
    for d in distros/*/; do
        p=$(cd "$d" && pwd -P); p=${p#/}; b="$HOME/Library/Caches/rexui/distros/${p//\//%}/bin"
        [ -d "$b" ] && { echo "${d%/}:"; ls -l "$b"; }
    done; true
