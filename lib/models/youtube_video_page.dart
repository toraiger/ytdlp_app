/// A committed YouTube video page. Tracking and timestamp parameters do not
/// change the selection; only YouTube Mix lists (RD...) create a queue.
class YoutubeVideoPage {
  const YoutubeVideoPage({required this.videoId, this.mixId});

  static final _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _mixIdPattern = RegExp(r'^RD[A-Za-z0-9_-]+$');
  static final home = Uri.https('www.youtube.com', '/');

  final String videoId;
  final String? mixId;
  bool get isMix => mixId != null;
  (String, String?) get key => (videoId, mixId);
  Uri get uri => Uri.https('www.youtube.com', '/watch', {
    'v': videoId,
    if (mixId != null) 'list': mixId!,
  });

  static bool isVideoId(String value) => _videoIdPattern.hasMatch(value);

  static bool allowsNavigation(Uri uri) {
    if (uri.toString() == 'about:blank') return true;
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return false;
    }
    return const [
      'youtube.com',
      'youtu.be',
      'google.com',
      'google.co.jp',
    ].any((domain) => uri.host == domain || uri.host.endsWith('.$domain'));
  }

  static YoutubeVideoPage? fromUri(Uri uri) {
    if (!allowsNavigation(uri) || uri.scheme != 'https') return null;
    String? id;
    if (uri.host == 'youtu.be') {
      if (uri.pathSegments.length == 1) id = uri.pathSegments.single;
    } else if (const [
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com',
    ].contains(uri.host)) {
      if (uri.path == '/watch') {
        id = uri.queryParameters['v'];
      } else if (uri.pathSegments.length == 2 &&
          const ['shorts', 'live'].contains(uri.pathSegments.first)) {
        id = uri.pathSegments[1];
      }
    }
    if (id == null || !isVideoId(id)) return null;
    final list = uri.queryParameters['list'];
    return YoutubeVideoPage(
      videoId: id,
      mixId: list != null && _mixIdPattern.hasMatch(list) ? list : null,
    );
  }
}
