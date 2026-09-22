#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[validate-driver] HAL driver build"
./drivers/micbridge-hal/scripts/build-driver.sh >/dev/null
echo "[validate-driver] Timing and sample integrity regression checks"
TEST_DIR="$(mktemp -d -t micbridge-driver-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++20 -O2 -fobjc-arc \
  -framework CoreAudio -framework CoreFoundation \
  drivers/micbridge-hal/tests/DriverTimingTests.mm -o "$TEST_DIR/driver-tests"
"$TEST_DIR/driver-tests"
echo "[validate-driver] OK"
