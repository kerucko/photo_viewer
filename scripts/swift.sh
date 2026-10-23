#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$PWD/.build/pm-cache"
if [[ "${1:-}" == "test" ]]; then
    FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
    if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
        set -- "$@" -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib"
    fi
fi
exec swift "$@" --disable-sandbox --cache-path "$PWD/.build/pm-cache"
