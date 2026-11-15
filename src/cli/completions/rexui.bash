# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: LicenseRef-rexui-1.0
_rexui() {
    local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]:-} d distros=()
    for d in "$HOME"/.config/rex/distros/*/; do [ -d "$d" ] && distros+=("$(basename "$d")"); done
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "load default list current build try check new loading embed pane launch completions help" -- "$cur"))
        return
    fi
    local words=() files=()
    case ${COMP_WORDS[COMP_CWORD-1]} in
    --split) [[ $cmd == embed || $cmd == pane || $cmd == launch ]] && { COMPREPLY=($(compgen -W "right left above below" -- "$cur")); return; } ;;
    --block) [[ $cmd == embed || $cmd == pane || $cmd == launch ]] && { COMPREPLY=(); return; } ;;
    esac
    case $cmd in
    load) [ "$COMP_CWORD" -eq 2 ] && words=("${distros[@]}" default) && files=($(compgen -d -- "$cur")) ;;
    build)
        if [ "$COMP_CWORD" -eq 2 ]; then words=(--stale "${distros[@]}"); files=($(compgen -d -- "$cur"))
        elif [ "$COMP_CWORD" -eq 3 ] && [ "${COMP_WORDS[2]}" = --stale ]; then words=("${distros[@]}"); files=($(compgen -d -- "$cur")); fi ;;
    try) [ "$COMP_CWORD" -eq 2 ] && words=(stop "${distros[@]}") && files=($(compgen -d -- "$cur") $(compgen -f -X '!*.rui' -- "$cur")) ;;
    check) [ "$COMP_CWORD" -eq 2 ] && words=("${distros[@]}") && files=($(compgen -d -- "$cur") $(compgen -f -X '!*.rui' -- "$cur")) ;;
    loading) words=(stop --hold) && files=($(compgen -f -X '!*.rui' -- "$cur")) ;;
    embed) words=(--split --tab --block --relative --crossover --library)
        files=($(compgen -d -X '!*.app' -- "$cur") $(compgen -c -- "$cur")) ;;
    pane) words=(--split --tab --block web)
        local w; for w in "$(rexui current 2>/dev/null)"/panes/*.rui; do [ -f "$w" ] && words+=("$(basename "$w" .rui)"); done
        files=($(compgen -f -X '!*.rui' -- "$cur")) ;;
    launch) words=(--split --tab --block)
        local IFS=$'\n' n; for n in $(rexui launch 2>/dev/null | sed -E 's/^[a-z]+ +//'); do words+=("$n"); done ;;
    completions) [ "$COMP_CWORD" -eq 2 ] && words=(zsh bash) ;;
    esac
    COMPREPLY=($(compgen -W "${words[*]}" -- "$cur") "${files[@]}")
}
complete -o filenames -F _rexui rexui
