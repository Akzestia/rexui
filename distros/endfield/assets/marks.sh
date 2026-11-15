#!/usr/bin/env bash
# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: MIT
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
out="$here/brand"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
marks=("wordmark" 'viewBox="0 0 74\.14 36\.99"' 7019379e194c1738e482bac6e6408a01535801c9153c5ded69bcfa20eed690ae 960
       "tri" 'Header_tri' 9cf153b8e607e4a16b047962df9005c35a4ac38a30e361d39fc14cd0879e93cd 256)
echo "the official page"
curl -fsSL --retry 2 -A "Mozilla/5.0 (rexui endfield)" -o "$tmp/page.html" https://endfield.gryphline.com/en-us/
xcrun swiftc -O -o "$tmp/svgpng" "$root/tools/svgpng.swift" 2> /dev/null
mkdir -p "$out"
for ((i = 0; i < ${#marks[@]}; i += 4)); do
    name=${marks[i]} find=${marks[i + 1]} want=${marks[i + 2]} width=${marks[i + 3]}
    FIND=$find perl -0777 -ne 'while (/(<svg\b[^>]*>.*?<\/svg>)/sg) { my $s = $1; if ($s =~ /$ENV{FIND}/) { print $s; last } }' \
        "$tmp/page.html" > "$tmp/$name.svg"
    [ -s "$tmp/$name.svg" ] || { echo "marks: no $name in the page (the site changed): nothing written" >&2; exit 1; }
    got=$(perl -0777 -ne 'my @d = /\sd="([^"]*)"/g; my ($v) = /viewBox="([^"]*)"/; print "$v|" . join("|", @d)' "$tmp/$name.svg" |
        shasum -a 256 | cut -c1-64)
    [ "$got" = "$want" ] || { echo "marks: the $name's shape isn't the one this was made for (the site changed): nothing written" >&2; exit 1; }
    "$tmp/svgpng" "$tmp/$name.svg" "$tmp/$name.png" "$width"
done
for name in wordmark tri; do cp "$tmp/$name.svg" "$tmp/$name.png" "$out/"; done
echo "done: assets/brand/wordmark and tri (.svg as the site has them, .png of each); endfield shows them as it loads again"
