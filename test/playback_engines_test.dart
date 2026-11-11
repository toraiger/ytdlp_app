import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/services/playback_engines.dart';
import "package:video_player/video_player.dart";

void main() {
  test('Native video player receives media URL and request headers', () async {
    final uri = Uri.parse('https://media.example.test/video.mp4');
    final headers = {'User-Agent': 'video-agent'};
    final engine = NativeVideoEngine(uri, headers);
    expect(engine.controller.dataSource, uri.toString());
    expect(engine.controller.httpHeaders, headers);
    await engine.dispose();
  });
  test("Native video failures expose codes without raw descriptions", () async {
    final engine = NativeVideoEngine(
      Uri.parse("https://media.example.test/video.mp4"),
      const {},
    );
    engine.controller.value = const VideoPlayerValue.erroneous(
      "Error Domain=AVFoundationErrorDomain Code=-11800 private-media-url",
    );
    expect(engine.value.hasError, isTrue);
    expect(engine.value.failure!.nativeCode, -11800);
    expect(engine.value.failure!.type, "PlatformException");
    await engine.dispose();
  });
}
