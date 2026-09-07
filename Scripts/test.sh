#!/bin/bash
set -euo pipefail
YAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$YAP_ROOT/../work"
export CLANG_MODULE_CACHE_PATH="$YAP_ROOT/../work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$YAP_ROOT/../work/module-cache"
export YAP_TEST_LOOPBACK="${YAP_TEST_LOOPBACK:-1}"
cd "$YAP_ROOT"
swift test --disable-sandbox --cache-path "$YAP_ROOT/../work/spm-cache" "$@"
