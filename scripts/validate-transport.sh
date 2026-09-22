#!/usr/bin/env zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BIN="$(mktemp -t micbridge-transport.XXXXXX)"
trap 'rm -f "$TEST_BIN"' EXIT
clang -O2 -std=c11 -Wall -Wextra -Werror -D_DARWIN_C_SOURCE \
  -I "$ROOT_DIR/packages/bridge-core/Sources/BridgeRT/include" \
  "$ROOT_DIR/packages/bridge-core/Sources/BridgeRT/BridgeRT.c" \
  "$ROOT_DIR/packages/bridge-core/Tests/TransportTests.c" -o "$TEST_BIN"
"$TEST_BIN"
