#!/usr/bin/env bash
set -euo pipefail

mix_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$mix_root"

mix_package_version=$(awk '/^version:/ { print $2; exit }' pubspec.yaml)
mix_version=${mix_package_version%%+*}
mix_build_number=${MIX_BUILD_NUMBER:-${mix_package_version#*+}}
if [[ ! "$mix_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
      ! "$mix_build_number" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' 'Expected version: x.y.z+number in pubspec.yaml and a positive MIX_BUILD_NUMBER.' >&2
  exit 1
fi

mix_revision=${MIX_APP_REVISION:-$(git rev-parse --short=7 HEAD 2>/dev/null || true)}
mix_revision=${mix_revision:0:7}

# The installed app and its visible label receive the same version and build.
exec bash scripts/flutterw build "$@" \
  --build-name="$mix_version" \
  --build-number="$mix_build_number" \
  --dart-define="APP_VERSION=$mix_version" \
  --dart-define="APP_BUILD_NUMBER=$mix_build_number" \
  --dart-define="APP_REVISION=$mix_revision"
