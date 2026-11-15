set working-directory := '../'

ts := "tools/editor/tree-sitter-rui"

[doc('Regenerate the tree-sitter parser (needs npm install there once), run its corpus, parse every example, check the queries, run rui-ls over the examples and its requests')]
check:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ts}}
    [ -d node_modules/tree-sitter-javascript ] || npm install --ignore-scripts
    tree-sitter generate
    tree-sitter test
    tree-sitter parse --quiet --stat ../../../distros/main/ui/*.rui ../../../distros/main/panes/*.rui | grep "Total parses"
    for q in queries/*.scm; do tree-sitter query "$q" ../../../distros/main/ui/clock.rui > /dev/null; done
    cd ../../..
    just editor::ls
    echo "editor checks pass"

[doc('rui-ls (tools/editor/rui-ls, C++ on the engine): every example without a diagnostic and its outline the tree the engine parses, formatting, components, and each request over stdio')]
ls:
    #!/usr/bin/env bash
    set -euo pipefail
    make -s -f jm/dylib.mk -j "$(sysctl -n hw.ncpu)" build/rui-ls
    mkdir -p build/test
    objs=$(ls build/obj/tools/editor/rui-ls/*.o | grep -v '/main.o$')
    xcrun clang++ -std=c++23 -arch arm64 -O2 -Wall -Wextra -Wshadow -Wconversion -Werror -Wno-missing-field-initializers -fno-exceptions -fno-rtti -ffp-contract=off \
        -I src -I tools -I build -o build/test/rui-ls-test tools/editor/rui-ls/test.cc $objs $(find build/obj/src/engine -name '*.o') -framework CoreFoundation -licucore
    build/test/rui-ls-test "$PWD" | grep -v '^PASS'
