set working-directory := '../'

bin := env("HOME") / ".local/bin"

[doc("Build rexui-mcp")]
build:
    bazel build //tools/mcp:rexui-mcp

[doc("Its tests")]
test:
    bazel test //tools/mcp:mcp_test --test_output=errors

[doc("A stable copy in ~/.local/bin, registered with Claude Code for every project (user scope)")]
install NAME='rexui': build
    #!/usr/bin/env sh
    set -eu
    mkdir -p "{{bin}}"
    install -m 0755 bazel-bin/tools/mcp/rexui-mcp "{{bin}}/rexui-mcp"
    claude mcp remove {{ NAME }} -s user >/dev/null 2>&1 || true
    claude mcp add -s user {{ NAME }} -- "{{bin}}/rexui-mcp"
    claude mcp list 2>/dev/null | grep {{ NAME }} || true
    echo "Ask pushes into a session started with: claude --dangerously-load-development-channels server:{{ NAME }}"

[doc("initialize, tools/list and selected_element against the running Rex UI, over stdio")]
probe: build
    #!/usr/bin/env sh
    set -eu
    { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"selected_element","arguments":{}}}'; sleep 1; } \
      | bazel-bin/tools/mcp/rexui-mcp
