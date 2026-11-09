# Mix Player's pinned just_audio source

Upstream: `just_audio` **0.10.6**, copied from the published pub.dev package.
The original `LICENSE`, package version, Android code and
web dependency are preserved. `lib`, `android`, `darwin`, the package manifest,
README and changelog are included; upstream examples and generated files are not.

Local changes:

- Progressive audio prefers a finite, positive `AVPlayerItem.duration` over a
  seekable window. HLS/DASH retain their seekable-window policy. Non-numeric
  times reach Dart as unknown rather than zero.
- Events capture index, position and duration from one source. Pending seeks and
  automatic advances retain their intended target until the native item changes.
- Completion is keyed to the item that ended, tolerates either KVO/notification
  order, ignores duplicate/stale completions and resets on explicit replay/load.
- The iOS-only `mixGetNativeTiming` method returns numeric timing diagnostics
  without URLs, headers, video IDs, asset metadata or player identifiers.
- `StreamAudioSource` accepts optional progressive source options so the app's
  iOS M4A byte-range repair retains precise AVFoundation timing. Its loopback
  URL uses `localhost`, matching the app's narrowly scoped ATS exception.
- Stream-proxy cancellation completes on disconnect/error as well as EOF,
  cancelling the upstream subscription when native seeks or reloads close it.

The shared policy is in `MixAudioTimeline.h/.m`; the Objective-C tests in the
application's `test/native` exercise that same production code on macOS CI.
Do not patch the pub cache. Upgrade by comparing these changes against a new
upstream release and rerunning native and Flutter tests plus device playback.
