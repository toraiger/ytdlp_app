enum AudioTransportRoute { unknown, direct, hls, m4aLoopback }

enum TransportResetState { notRequested, completed, failed }

enum MediaTransferStage { notStarted, prefix, range }

enum MediaTransferFailure {
  none,
  connection,
  timeout,
  httpStatus,
  invalidResponse,
  cancelled,
  closed,
}

/// Only enums, counts and status codes are retained; request data stays private.
class MediaTransferDiagnostics {
  const MediaTransferDiagnostics({
    this.attempts = 0,
    this.stage = MediaTransferStage.notStarted,
    this.failure = MediaTransferFailure.none,
    this.httpStatus,
    this.nativeCode,
  });

  final int attempts;
  final MediaTransferStage stage;
  final MediaTransferFailure failure;
  final int? httpStatus;
  final int? nativeCode;
}

class AudioTransportDiagnostics {
  const AudioTransportDiagnostics({
    this.route = AudioTransportRoute.unknown,
    this.reset = TransportResetState.notRequested,
    this.proxyGeneration = 0,
    this.proxyListening = false,
    this.localRequestCount = 0,
    this.upstream,
  });

  final AudioTransportRoute route;
  final TransportResetState reset;
  final int proxyGeneration;
  final bool proxyListening;
  final int localRequestCount;
  final MediaTransferDiagnostics? upstream;
}
