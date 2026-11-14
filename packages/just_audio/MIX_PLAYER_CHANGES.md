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
- The loopback listener shares pending starts and awaits forced shutdown. Bind
  failure and an old listener's completion cannot leave stale running state.
  Unknown routes return 404 and unsupported methods return 405.
- `AudioPlayer.resetLocalProxy()` can be called after stopping playback to drop
  old routes and rebind on the next load, preserving the one-player background
  service. `localProxySnapshot` exposes only generation/count/listening values.
- The preparation event channel reports ready/failed items by source identity,
  including future items. Future failures hold the intended successor without
  emitting a fatal error for the active item or skipping to a later song.
- The iOS `mixHoldUpcoming`, `mixReplaceUpcoming` and `mixRetirePlayed` methods
  verify native item identity on the main thread. They preserve the current
  decoder when Dart index events arrive late. Dart and the background handler's
  playlist are synchronized after a successful guarded mutation.
- Guarded replacement and retirement results use explicit CFBoolean values.
  Boxing Objective-C logical expressions directly produces integers, which
  fail Dart's `invokeMethod<bool>` cast even when the native mutation succeeds.
- `rotateLocalProxy()` assigns fresh routes to new sources while keeping active
  routes alive. Replaced/played sources release their routes; a retired listener
  closes when its last source is released. Stop/reset/dispose close all listeners.

The shared policy is in `MixAudioTimeline.h/.m`; the Objective-C tests in the
application's `test/native` exercise that same production code on macOS CI.
Do not patch the pub cache. Upgrade by comparing these changes against a new
upstream release and rerunning native and Flutter tests plus device playback.
