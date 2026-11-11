import "api_models.dart";

enum QueueItemSource { mix, manual }

enum QueueInsertPosition { next, last }

/// A video may occur repeatedly; entryId identifies one occurrence, not media.
class MixQueueItem {
  const MixQueueItem({
    required this.entryId,
    required this.track,
    required this.source,
  });

  final String entryId;
  final MixTrack track;
  final QueueItemSource source;
}
