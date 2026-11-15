#!/bin/sh
# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: GPL-3.0-only
exec /usr/bin/perl -e '
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "rexui_media_main") or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::run", $sym);
    run();
' "$(dirname "$0")/librexui-media.dylib"
