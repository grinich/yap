#!/bin/bash
set -euo pipefail
WHOOSH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$WHOOSH_ROOT/../work"
export CLANG_MODULE_CACHE_PATH="$WHOOSH_ROOT/../work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WHOOSH_ROOT/../work/module-cache"
export WHOOSH_TEST_LOOPBACK="${WHOOSH_TEST_LOOPBACK:-1}"
cd "$WHOOSH_ROOT"
swift test --disable-sandbox --cache-path "$WHOOSH_ROOT/../work/spm-cache" "$@"
