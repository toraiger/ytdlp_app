import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:mix_player_app/models/api_models.dart';
import 'package:mix_player_app/services/playback_engines.dart';

void main() {
  test("Repeated media uses distinct native queue identities", () {
    const track = MixTrack(videoId: "same-video", title: "Same video");
    final uri = Uri.parse("https://media.example.test/same.m4a");
    final identifiers = ["first-occurrence", "second-occurrence"];
    final sources =
        identifiers
            .map(
              (entryId) => createAudioSource(
                QueueEntry(track: track, entryId: entryId, uri: uri),
              ),
            )
            .cast<ProgressiveAudioSource>();
    expect(sources.map((source) => (source.tag as MediaItem).id), identifiers);
  });
  test(
    'Audio VOD requests precise Apple timing and preserves media metadata',
    () {
      final entry = QueueEntry(
        track: const MixTrack(
          videoId: 'a',
          title: 'Track a',
          channel: 'Artist a',
          duration: Duration(seconds: 120),
        ),
        uri: Uri.parse(
          'https://media.example.test/videoplayback?signature=test',
        ),
        httpHeaders: const {'User-Agent': 'audio-agent'},
        streamDuration: const Duration(milliseconds: 237125),
      );
      final source = createAudioSource(entry) as ProgressiveAudioSource;
      expect(source.uri, entry.uri);
      expect(source.headers, entry.httpHeaders);
      expect(
        source.options?.darwinAssetOptions?.preferPreciseDurationAndTiming,
        isTrue,
      );
      final tag = source.tag as MediaItem;
      expect(tag.id, 'a');
      expect(tag.title, 'Track a');
      expect(tag.artist, 'Artist a');
      expect(tag.duration, const Duration(milliseconds: 237125));
    },
  );
  test('API HLS transport is honored for URLs without a manifest suffix', () {
    for (final protocol in ['m3u8', 'm3u8_native']) {
      final entry = QueueEntry(
        track: const MixTrack(videoId: 'b', title: 'Track b'),
        uri: Uri.parse('https://media.example.test/manifest/expire/2000000000'),
        httpHeaders: const {'Referer': 'https://youtube.com/'},
        format: StreamFormat(protocol: protocol, ext: 'm4a'),
      );
      final source = createAudioSource(entry) as HlsAudioSource;
      expect(source.uri, entry.uri);
      expect(source.headers, entry.httpHeaders);
      expect((source.tag as MediaItem).id, 'b');
    }
  });
  test('Legacy direct manifest URLs retain transport detection', () {
    const track = MixTrack(
      videoId: 'direct',
      title: 'Direct',
      duration: Duration(seconds: 120),
    );
    final hls = createAudioSource(
      QueueEntry(
        track: track,
        uri: Uri.parse('https://media.example.test/audio.m3u8'),
      ),
    );
    final dash = createAudioSource(
      QueueEntry(
        track: track,
        uri: Uri.parse('https://media.example.test/audio.mpd'),
      ),
    );
    expect(hls, isA<HlsAudioSource>());
    expect(dash, isA<DashAudioSource>());
    expect(((hls as HlsAudioSource).tag as MediaItem).duration, track.duration);
  });
  test('Native video player receives media URL and request headers', () async {
    final uri = Uri.parse('https://media.example.test/video.mp4');
    final headers = {'User-Agent': 'video-agent'};
    final engine = NativeVideoEngine(uri, headers);
    expect(engine.controller.dataSource, uri.toString());
    expect(engine.controller.httpHeaders, headers);
    await engine.dispose();
  });
}
