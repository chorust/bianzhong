#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
if [[ -d "$CLT_FRAMEWORKS/Testing.framework" ]] && [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]]; then
  exec swift test --disable-xctest -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" "$@"
else
  exec swift test "$@"
fi
