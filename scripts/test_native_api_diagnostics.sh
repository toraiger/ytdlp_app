#!/usr/bin/env bash
set -euo pipefail

mix_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mix_build=$(mktemp -d "${TMPDIR:-/tmp}/mix-api-tests.XXXXXX")
trap 'rm -rf "$mix_build"' EXIT
cd "$mix_root"

# Flutter's VM tests do not build FFI plugins. Build the locked dependency's
# macOS forwarders so this test can exercise a real Foundation NSError.
mix_objc=$(python3 - "$mix_root/.dart_tool/package_config.json" <<'PY'
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urljoin, urlparse
config = Path(sys.argv[1])
package = next(p for p in json.loads(config.read_text())["packages"] if p["name"] == "objective_c")
print(unquote(urlparse(urljoin(config.as_uri(), package["rootUri"])).path))
PY
)
mkdir -p "$mix_build/objective_c.framework"
xcrun clang -dynamiclib -fobjc-arc -Wno-deprecated-declarations \
  -framework Foundation -undefined dynamic_lookup \
  "$mix_objc/macos/Classes/objective_c.m" \
  "$mix_objc/macos/Classes/objective_c.c" \
  -o "$mix_build/objective_c.framework/objective_c"

mix_flutter_root=$(python3 - "$(command -v flutter)" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().parent.parent)
PY
)
# Invoke Dart directly so macOS does not strip DYLD_* while starting a shell.
DYLD_FRAMEWORK_PATH="$mix_build${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" \
  "$mix_flutter_root/bin/cache/dart-sdk/bin/dart" \
  "$mix_flutter_root/bin/cache/flutter_tools.snapshot" \
  test --no-pub test/native_api_error_test.dart
