import "package:flutter_test/flutter_test.dart";
import "package:mix_player_app/models/youtube_video_page.dart";

void main() {
  test(
    "Long-press messages normalize video URLs and discard Mix parameters",
    () {
      final target = YoutubeVideoTarget.fromMessage({
        "url":
            "https://m.youtube.com/watch?v=aaaaaaaaaaa&list=RDaaaaaaaaaaa&t=50",
        "title": "  Video title  ",
      });
      expect(
        target?.page.uri.toString(),
        "https://www.youtube.com/watch?v=aaaaaaaaaaa",
      );
      expect(target?.title, "Video title");
    },
  );

  test("Malformed and non-video targets are rejected before any API call", () {
    for (final message in [
      null,
      [],
      {"url": 42},
      {"url": "https://youtube.com.evil.test/watch?v=aaaaaaaaaaa"},
      {"url": "http://youtube.com/watch?v=aaaaaaaaaaa"},
      {"url": "https://youtube.com/watch?v=invalid"},
      {"url": "https://youtube.com/@channel"},
      {"url": "javascript:alert(1)"},
    ]) {
      expect(YoutubeVideoTarget.fromMessage(message), isNull);
    }
  });
}
