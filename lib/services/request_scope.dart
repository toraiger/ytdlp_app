import "dart:async";

/// A preparation owns its requests; cancelling it never closes the API client
/// shared with Mix loading or the current song.
class RequestScope {
  RequestScope(this.networkGeneration);
  final int networkGeneration;
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const RequestCancelled();
  }
}

class RequestCancelled implements Exception {
  const RequestCancelled();
}
