import 'api_models.dart';
import 'native_playback_timing.dart';

/// Playback timing and format metadata; no URLs, video IDs or credentials.
class PlaybackDiagnostics {
  const PlaybackDiagnostics({
    required this.mode,
    required this.queueLength,
    required this.mediaPosition,
    this.listIndex,
    this.playerIndex,
    this.listDuration,
    this.apiDuration,
    this.mediaDuration,
    this.formatId,
    this.mediaExtension,
    this.mediaProtocol,
    this.audioCodec,
    this.nativeTiming = const [],
  });

  final PlaybackMode mode;
  final int queueLength;
  final int? listIndex;
  final int? playerIndex;
  final Duration? listDuration;
  final Duration? apiDuration;
  final Duration? mediaDuration;
  final Duration mediaPosition;
  final String? formatId;
  final String? mediaExtension;
  final String? mediaProtocol;
  final String? audioCodec;
  final List<NativePlaybackTiming> nativeTiming;
}
