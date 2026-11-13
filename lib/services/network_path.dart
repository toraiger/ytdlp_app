import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

class NetworkPath {
  const NetworkPath({required this.generation, required this.available});
  final int generation;
  final bool available;
}

/// The native monitor remains active while audio plays with the screen locked.
Stream<NetworkPath> networkPaths() {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
    return const Stream.empty();
  }
  return const EventChannel(
    "jp.toraiger.mixPlayerApp/networkPath",
  ).receiveBroadcastStream().map((event) {
    final values = event as Map;
    return NetworkPath(
      generation: values["generation"] as int,
      available: values["available"] == true,
    );
  });
}
