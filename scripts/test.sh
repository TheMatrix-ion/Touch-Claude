#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_CACHE="$ROOT_DIR/.build-cache/tests"
TEST_BIN="$BUILD_CACHE/PetCoreTests"

mkdir -p "$BUILD_CACHE/clang/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE/clang/ModuleCache"

swiftc \
  -o "$TEST_BIN" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/PetState.swift" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/PetRules.swift" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/PetEngine.swift" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/PetStore.swift" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/TranscriptUsage.swift" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/ModeSignal.swift" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/PokeSignal.swift" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/StopEventQueue.swift" \
  "$ROOT_DIR/Sources/ClaudeTouchBar/PetCLI.swift" \
  "$ROOT_DIR/Tests/PetCoreTests.swift"

"$TEST_BIN"
python3 "$ROOT_DIR/Tests/ConfigureStopHookTests.py"
