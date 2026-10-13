#!/usr/bin/env bash
set -euo pipefail

mix_project_root="$(cd "$(dirname "$0")/.." && pwd)"
mix_flutter_root=/workspace/.tooling/flutter
mix_flutter_revision=fcf2c11572af6f390246c056bc905eca609533a0

if [[ ! -x "$mix_flutter_root/bin/flutter" ]]; then
  mkdir -p /workspace/.tooling
  git clone --depth 1 --branch 3.32.5 https://github.com/flutter/flutter.git "$mix_flutter_root"
fi
if [[ "$(git -C "$mix_flutter_root" rev-parse HEAD)" != "$mix_flutter_revision" ]]; then
  echo "The existing cloud Flutter SDK differs from the project's pinned version." >&2
  exit 1
fi
cd "$mix_project_root"
bash scripts/flutterw precache --web --linux
bash scripts/flutterw pub get --enforce-lockfile
