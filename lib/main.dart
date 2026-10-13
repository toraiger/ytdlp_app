import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'player_app.dart';
import 'services/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android)) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'jp.toraiger.mix_player_app.audio',
      androidNotificationChannelName: 'Mix Player',
      androidNotificationOngoing: true,
    );
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }
  runApp(PlayerApp(settings: AppSettings()));
}
