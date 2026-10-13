import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/models/api_models.dart';
import 'support/fakes.dart';

void main() {
  test('UT-01 Mix JSON maps session, metadata and numeric durations', () {
    final model = MixResponse.fromJson(mixJson(['a', 'b']));
    expect(model.sessionId, 'session-1');
    expect(model.playlistId, 'RD-test');
    expect(model.playlistTitle, 'Test Mix');
    expect(model.expiresAt?.isUtc, isTrue);
    expect(model.items[0].videoId, 'a');
    expect(model.items[0].duration, const Duration(minutes: 2));
    expect(model.items[0].channel, 'Artist a');
  });
  test('Duration supports seconds, mm:ss and hh:mm:ss', () {
    expect(parseDuration('03:24'), const Duration(minutes: 3, seconds: 24));
    expect(
      parseDuration('1:02:03'),
      const Duration(hours: 1, minutes: 2, seconds: 3),
    );
    expect(parseDuration('1.5'), const Duration(milliseconds: 1500));
    expect(parseDuration(-1), isNull);
    expect(parseDuration('unknown'), isNull);
  });
  test('UT-02 Stream JSON distinguishes audio and muxed video URLs', () {
    final model = StreamResponse.fromJson(streamJson('a'));
    expect(model.audio?.url?.path, '/a.m4a');
    expect(model.videoAudio?.url?.path, '/a.mp4');
  });
  test('UT-03 Merge keeps original order and first copy of video_id', () {
    MixTrack track(String id) => MixTrack.fromJson(trackJson(id));
    final merged = mergeTracks(
      [track('a'), track('b')],
      [track('b'), track('c'), track('a')],
    );
    expect(merged.map((t) => t.videoId), ['a', 'b', 'c']);
  });
  test('Only HTTPS media URLs without embedded credentials are playable', () {
    for (final url in [
      'http://media.test/a',
      'file:///a',
      'https:///a',
      'https://key@media.test/a',
    ]) {
      expect(playableUri(url), isNull);
    }
    expect(
      playableUri('https://media.test/a?signature=example')?.query,
      'signature=example',
    );
  });
  test('Malformed required fields are rejected', () {
    expect(
      () => MixResponse.fromJson({'session_id': 's'}),
      throwsFormatException,
    );
    expect(() => MixTrack.fromJson({'title': 'No ID'}), throwsFormatException);
  });
}
