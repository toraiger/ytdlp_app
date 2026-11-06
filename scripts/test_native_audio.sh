#!/usr/bin/env bash
set -euo pipefail

mix_native_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mix_native_source="$mix_native_root/packages/just_audio/darwin/just_audio/Sources/just_audio"
mix_native_build=$(mktemp -d "${TMPDIR:-/tmp}/mix-audio-tests.XXXXXX")
trap 'rm -rf "$mix_native_build"' EXIT

xcrun clang -fobjc-arc -Wall -Wextra -Werror \
  -framework Foundation -framework CoreMedia \
  -I "$mix_native_source/include/just_audio" \
  "$mix_native_source/MixAudioTimeline.m" \
  "$mix_native_root/test/native/audio_timeline_test.m" \
  -o "$mix_native_build/audio_timeline_test"
"$mix_native_build/audio_timeline_test"
