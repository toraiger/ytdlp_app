import 'api_models.dart';

/// Numeric playback information only; no URLs, identifiers or credentials.
class PlaybackDiagnostics {
  const PlaybackDiagnostics({
    required this.mode,
    required this.queueLength,
    required this.mediaPosition,
    this.listIndex,
    this.playerIndex,
    this.listDuration,
    this.mediaDuration,
  });

  final PlaybackMode mode;
  final int queueLength;
  final int? listIndex;
  final int? playerIndex;
  final Duration? listDuration;
  final Duration? mediaDuration;
  final Duration mediaPosition;
}
