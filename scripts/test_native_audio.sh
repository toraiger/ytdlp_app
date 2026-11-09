#!/usr/bin/env bash
set -euo pipefail

mix_native_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mix_native_source="$mix_native_root/packages/just_audio/darwin/just_audio/Sources/just_audio"
mix_native_build=$(mktemp -d "${TMPDIR:-/tmp}/mix-audio-tests.XXXXXX")
mix_media_pid=
cleanup() {
  if [[ -n "$mix_media_pid" ]]; then kill "$mix_media_pid" 2>/dev/null || true; fi
  rm -rf "$mix_native_build"
}
trap cleanup EXIT

xcrun clang -fobjc-arc -Wall -Wextra -Werror \
  -framework Foundation -framework CoreMedia \
  -I "$mix_native_source/include/just_audio" \
  "$mix_native_source/MixAudioTimeline.m" \
  "$mix_native_root/test/native/audio_timeline_test.m" \
  -o "$mix_native_build/audio_timeline_test"
"$mix_native_build/audio_timeline_test"

cp "$mix_native_root/test/fixtures/dash-tone.m4a" "$mix_native_build/dash-tone.m4a"
dart --suppress-analytics "$mix_native_root/scripts/normalize_m4a_fixture.dart" \
  "$mix_native_build/dash-tone.m4a" "$mix_native_build/normalized.m4a"
python3 "$mix_native_root/test/native/media_server.py" \
  "$mix_native_build" "$mix_native_build/port" &
mix_media_pid=$!
for mix_port_attempt in {1..100}; do
  [[ -s "$mix_native_build/port" ]] && break
  sleep 0.1
done
mix_media_port=$(cat "$mix_native_build/port")
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -framework Foundation -framework CoreMedia -framework AVFoundation \
  "$mix_native_root/test/native/m4a_asset_test.m" \
  -o "$mix_native_build/m4a_asset_test"
"$mix_native_build/m4a_asset_test" \
  "$mix_native_build/dash-tone.m4a" "$mix_native_build/normalized.m4a" \
  "http://127.0.0.1:$mix_media_port"
