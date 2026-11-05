import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/models/youtube_video_page.dart';

void main() {
  const id = 'a1B2c3D4e5F';
  test('Recognizes watch, mobile, Shorts, live and short links', () {
    for (final url in [
      'https://www.youtube.com/watch?v=$id',
      'https://m.youtube.com/watch?v=$id&t=90',
      'https://youtube.com/shorts/$id',
      'https://www.youtube.com/live/$id',
      'https://youtu.be/$id?si=dummy',
    ]) {
      final page = YoutubeVideoPage.fromUri(Uri.parse(url));
      expect(page?.videoId, id);
      expect(page?.isMix, isFalse);
      expect(page?.uri.toString(), 'https://www.youtube.com/watch?v=$id');
    }
  });
  test('Only RD Mix lists create a queue and tracking params are ignored', () {
    final mix =
        YoutubeVideoPage.fromUri(
          Uri.parse('https://youtube.com/watch?v=$id&list=RD$id&index=3&t=12'),
        )!;
    expect(mix.isMix, isTrue);
    expect(mix.mixId, 'RD$id');
    expect(
      mix.key,
      YoutubeVideoPage.fromUri(
        Uri.parse('https://m.youtube.com/watch?list=RD$id&v=$id'),
      )!.key,
    );
    expect(
      YoutubeVideoPage.fromUri(
        Uri.parse('https://youtube.com/watch?v=$id&list=PLdummy'),
      )?.isMix,
      isFalse,
    );
  });
  test(
    'Rejects lookalikes, credentials, non-HTTPS, other ports and invalid IDs',
    () {
      for (final url in [
        'http://youtube.com/watch?v=$id',
        'https://youtube.com.evil.test/watch?v=$id',
        'https://evilyoutube.com/watch?v=$id',
        'https://google.com/watch?v=$id',
        'https://user:password@youtube.com/watch?v=$id',
        'https://youtube.com:444/watch?v=$id',
        'https://www.youtube.com/watch?v=invalid',
        'https://www.youtube.com/embed/$id',
        'https://www.youtube.com/results?search_query=music',
        'intent://watch?v=$id',
      ]) {
        expect(YoutubeVideoPage.fromUri(Uri.parse(url)), isNull, reason: url);
      }
    },
  );
}
