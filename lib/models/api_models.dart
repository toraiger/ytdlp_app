enum PlaybackMode { audio, video }

Uri? playableUri(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

Map<String, dynamic> jsonObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object');
  }
  return value;
}

String requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing $key');
  }
  return value;
}

Duration? parseDuration(Object? value) {
  if (value is num && value.isFinite && value >= 0) {
    return Duration(milliseconds: (value * 1000).round());
  }
  if (value is String) {
    final seconds = num.tryParse(value);
    if (seconds != null) return parseDuration(seconds);
    final parts = value.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    var total = 0;
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0) return null;
      total = total * 60 + number;
    }
    return Duration(seconds: total);
  }
  return null;
}

class MixTrack {
  const MixTrack({
    required this.videoId,
    required this.title,
    this.index = 0,
    this.channel = '',
    this.duration,
    this.thumbnail,
    this.webpageUrl,
  });

  factory MixTrack.fromJson(Map<String, dynamic> json) {
    final id = requiredString(json, 'video_id');
    return MixTrack(
      index: (json['index'] as num?)?.toInt() ?? 0,
      videoId: id,
      title: json['title'] as String? ?? id,
      channel: json['channel'] as String? ?? '',
      duration: parseDuration(json['duration']),
      thumbnail: playableUri(json['thumbnail']),
      webpageUrl: playableUri(json['webpage_url']),
    );
  }

  final int index;
  final String videoId;
  final String title;
  final String channel;
  final Duration? duration;
  final Uri? thumbnail;
  final Uri? webpageUrl;
}

List<MixTrack> mergeTracks(
  Iterable<MixTrack> first,
  Iterable<MixTrack> second,
) {
  final seen = <String>{};
  return [
    for (final track in [...first, ...second])
      if (seen.add(track.videoId)) track,
  ];
}

class MixResponse {
  const MixResponse({
    required this.sessionId,
    required this.items,
    this.playlistId,
    this.playlistTitle,
    this.seedVideoId,
    this.expiresAt,
  });

  factory MixResponse.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) throw const FormatException('Missing items');
    return MixResponse(
      sessionId: requiredString(json, 'session_id'),
      playlistId: json['playlist_id'] as String?,
      playlistTitle: json['playlist_title'] as String?,
      seedVideoId: json['seed_video_id'] as String?,
      items: items.map((item) => MixTrack.fromJson(jsonObject(item))).toList(),
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
    );
  }

  final String sessionId;
  final String? playlistId;
  final String? playlistTitle;
  final String? seedVideoId;
  final List<MixTrack> items;
  final DateTime? expiresAt;
}

class StreamFormat {
  const StreamFormat({
    this.formatId,
    this.ext,
    this.protocol,
    this.vcodec,
    this.acodec,
    this.url,
  });

  factory StreamFormat.fromJson(Map<String, dynamic> json) => StreamFormat(
    formatId: json['format_id']?.toString(),
    ext: json['ext'] as String?,
    protocol: json['protocol'] as String?,
    vcodec: json['vcodec'] as String?,
    acodec: json['acodec'] as String?,
    url: playableUri(json['url']),
  );

  final String? formatId;
  final String? ext;
  final String? protocol;
  final String? vcodec;
  final String? acodec;
  final Uri? url;
}

class StreamResponse {
  const StreamResponse({
    required this.videoId,
    this.title,
    this.audio,
    this.videoAudio,
  });

  factory StreamResponse.fromJson(Map<String, dynamic> json) => StreamResponse(
    videoId: requiredString(json, 'video_id'),
    title: json['title'] as String?,
    audio:
        json['audio'] == null
            ? null
            : StreamFormat.fromJson(jsonObject(json['audio'])),
    videoAudio:
        json['video_audio'] == null
            ? null
            : StreamFormat.fromJson(jsonObject(json['video_audio'])),
  );

  final String videoId;
  final String? title;
  final StreamFormat? audio;
  final StreamFormat? videoAudio;
}
