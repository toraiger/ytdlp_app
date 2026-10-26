import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/services/playback_engines.dart';

void main() {
  test('Native video player receives media URL and request headers', () async {
    final uri = Uri.parse('https://media.example.test/video.mp4');
    final headers = {'User-Agent': 'video-agent'};
    final engine = NativeVideoEngine(uri, headers);
    expect(engine.controller.dataSource, uri.toString());
    expect(engine.controller.httpHeaders, headers);
    await engine.dispose();
  });
}
