import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

const defaultMixUrl =
    'https://m.youtube.com/watch?v=PDSkFeMVNFs&list=RDPDSkFeMVNFs';

class SettingsSnapshot {
  const SettingsSnapshot({
    this.serverUrl = '',
    this.apiKey = '',
    this.lastMix = defaultMixUrl,
  });

  final String serverUrl;
  final String apiKey;
  final String lastMix;
}

abstract interface class SettingsStore {
  Future<SettingsSnapshot> load();
  Future<void> saveConnection({
    required String serverUrl,
    required String apiKey,
  });
  Future<void> saveLastMix(String url);
}

class AppSettings implements SettingsStore {
  AppSettings({
    FlutterSecureStorage? secureStorage,
    SharedPreferencesAsync? preferences,
  }) : _secure = secureStorage ?? const FlutterSecureStorage(),
       _preferences = preferences ?? SharedPreferencesAsync();

  final FlutterSecureStorage _secure;
  final SharedPreferencesAsync _preferences;
  static const apiKeyName = 'mix_player.api_key';
  static const serverUrlName = 'mix_player.server_url';
  static const lastMixName = 'mix_player.last_mix';

  @override
  Future<SettingsSnapshot> load() async => SettingsSnapshot(
    serverUrl: await _preferences.getString(serverUrlName) ?? '',
    apiKey: await _secure.read(key: apiKeyName) ?? '',
    lastMix: await _preferences.getString(lastMixName) ?? defaultMixUrl,
  );

  @override
  Future<void> saveConnection({
    required String serverUrl,
    required String apiKey,
  }) async {
    await _secure.write(key: apiKeyName, value: apiKey);
    await _preferences.setString(serverUrlName, serverUrl);
  }

  @override
  Future<void> saveLastMix(String url) =>
      _preferences.setString(lastMixName, url);
}
