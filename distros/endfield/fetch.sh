#!/usr/bin/env bash
# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: MIT
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bash "$here/fonts/fetch.sh"
