# Mix Player / Flutter アプリ機能仕様書
**Document ID:** MP-FL-SPEC-001   **Version:** 0.1   **Date:** 2026-10-09   **Status:** Prototype specification

**Scope:** Flutter client (iPhone as primary target) + existing FastAPI contract. **Source:** MixPlayerFlutterStarter.zip / app_src. **Package:** mix_player_app 0.1.0+1.

既存の Docker Compose / FastAPI `/mix`, `/mix/{session_id}/extend`, `/stream` を使います。 サーバーは変更しません。Flutter アプリが動画・音声URLを受け取り、iPhoneがメディア配信元へ直接HTTPS接続します。PCからiPhoneへの配信は行いません。

**設計の原則:** ローカルPCからiPhoneにメディアを配信しない。APIのJSONをOracle Cloudから取得し、メディア本体はiPhoneが配信元へ直接HTTPS接続する。

> この文書は現在のソースに対応した仕様です。実機検証前の機能を動作保証済みとは扱いません。

## 1. 目的・適用範囲

**目的:** YouTube Mix URLから楽曲一覧を取得し、各video_idに対して新しい再生URLを解決し、iPhoneで音声・動画を再生する。

**対象:** 個人用の技術検証プロトタイプ。iPhoneが主対象、WindowsではAndroidによる先行テストを行う。

**対象外:** DRM解除、オフライン保存、認証の回避、強制終了後の自動再生、App Store配信保証は本プロトタイプの対象外。

## 2. システム構成・通信経路

```text
iPhone Flutter UI
  |-- POST /mix ------------------> Oracle Cloud FastAPI
  |-- POST /mix/{session_id}/extend -> FastAPI
  |-- POST /stream --------------> FastAPI / yt-dlp / PO Token
  |<------------- JSON: playable media URL
  +-- HTTPS M4A / MP4 ----------> Media delivery origin
```

Flutter内では`MixController`がセッションと楽曲一覧を管理し、`PlaybackController`が再生状態とキューを管理する。`ApiClient`はリクエストとJSON変換を担当する。

| Component | Source file | Responsibility |
| --- | --- | --- |
| Bootstrap | lib/main.dart | JustAudioBackground.init + AudioSession.music + MaterialApp |
| UI | lib/player_app.dart | URL input, track list, dialogs, seek, controls, video panel |
| Mix state | lib/controllers/mix_controller.dart | Load, deduplicate, extend session |
| Playback state | lib/controllers/playback_controller.dart | Audio playlist, video playback, direct URL |
| API | lib/services/api_client.dart | HTTPS POST, X-API-Key, 90-second timeout |
| Models | lib/models/api_models.dart | Decode playlist and stream JSON |
| Persistence | lib/services/app_settings.dart | Keychain / SharedPreferencesAsync |

## 3. 動作環境・依存パッケージ

- Flutter **3.32系以上**（本サンプルは Dart **3.7以上**を想定、3.32.5 / Dart 3.8.1 を意識して依存ライブラリを固定）
- Windows: Flutter SDK がPATHにあること。Androidを使えば Windows から UI・API・基本的な音声再生を検証可能
- iPhoneへのビルド・インストール: **Mac + Xcode + Apple Account** が必要。Flutterであっても Windows 単独では iOS アプリをビルドできません
- 本稼働のAPI URL: HTTPS で公開された Oracle Cloud などのサーバーURL
- APIキー: アプリの設定画面から入力。ソースには直接記述しないでください

このZIPは `.ipa` ではなく**ソース一式**です。`ios/`, `android/` は `flutter create` で生成します。

| Package | Pinned version | Use |
| --- | --- | --- |
| http | 1.6.0 | API transport |
| just_audio | 0.10.6 | Audio queue |
| just_audio_background | 0.0.1-beta.17 | Background playback and media controls |
| audio_session | 0.2.4 | Audio session |
| video_player | 2.10.1 | Foreground MP4 |
| flutter_secure_storage | 10.3.4 | Secure API key |
| shared_preferences | 2.5.3 | Non-secret settings |
| flutter_lints | 5.0.0 | Static analysis |

**Dart constraint:** `>=3.7.0 <4.0.0`  /  **Flutter:** 3.32系以上を想定。iOSでの実機ビルドにはMac / Xcodeが必要。

## 4. 画面仕様・操作フロー

| UI area | Visible label / field | Action |
| --- | --- | --- |
| AppBar | Mix Player / APIサーバー設定 | 接続設定ダイアログ |
| Settings dialog | HTTPS API URL / X-API-Key | Validate and save |
| Main input | YouTube Mix URL | Edit source URL |
| Mode | 音声のみ / 動画＋音声 | Select before playback |
| Load | Mixを20曲取得 | POST /mix |
| Direct test | 直接URLで再生テスト | Play HTTPS M4A/MP4 without API |
| Track list | title / channel / thumbnail | Tap to resolve and play |
| Extend | 曲を追加取得 | POST /extend |
| Mini player | 前の曲 / 再生 / 次の曲 / 停止 | Transport + seek |
| Video panel | VideoPlayer | Visible in video mode |

**画面初期値:** Mix URLはサンプルURLが入力済み。再起動後は最後に保存したMix URLを復元する。サーバー未設定時はガイドを表示する。

## 5. 機能要件一覧

| ID | Function | Source / behavior | Status |
| --- | --- | --- | --- |
| FR-01 | API connection | HTTPS URL + secret key save | 実装済み／実機未検証 |
| FR-02 | Mix fetch | POST /mix (default count=20) | 実装済み／実機未検証 |
| FR-03 | Track display | Thumbnail, title, channel, selection | 実装済み／実機未検証 |
| FR-04 | Extend | Manual + at queue end / unique video_id | 実装済み／実機未検証 |
| FR-05 | Audio | M4A via just_audio | 実装済み／実機未検証 |
| FR-06 | Audio queue | Current + approximately 2 upcoming | 実装済み／実機未検証 |
| FR-07 | Video | MP4 via video_player, foreground only | 実装済み／実機未検証 |
| FR-08 | Transport | Play, pause, next, previous, stop, seek | 実装済み／実機未検証 |
| FR-09 | Background | Audio mode, background plugin + audio mode | 実装済み／実機未検証 |
| FR-10 | Direct URL | HTTPS signed URL test | 実装済み／実機未検証 |
| FR-11 | URL expiry recovery | Refresh failed media URL automatically | 未実装（拡張候補） |
| FR-12 | Session recovery | Recreate expired /mix session | 未実装（拡張候補） |
| FR-13 | Persistent queue | Restore queue and playback location | 未実装（拡張候補） |
| FR-14 | Uninterrupted long playback | Bounded retry + robust background handling | 未実装（拡張候補） |

## 6. API連携仕様

```text
POST /mix
Content-Type: application/json
X-API-Key: <key>
{"url":"https://m.youtube.com/watch?v=...&list=...", "count":20}

POST /stream
Content-Type: application/json
X-API-Key: <key>
{"video_id":"PDSkFeMVNFs"}

POST /mix/{session_id}/extend
Content-Type: application/json
X-API-Key: <key>
{"count":20}
```

`/stream` の戻り値は `audio.url` (M4A) と `video_audio.url` (MP4) を使います。曲一覧の追加APIが全件を返しても追加分のみを返しても、`video_id` の重複を排除して結合します。サーバーのMixセッションは1時間で失効する設計のため、失効後は再度 `/mix` を呼び出してください。

| API | Request body | Main response data | Remarks |
| --- | --- | --- | --- |
| POST /mix | url: string, count: 20 | session_id / playlist_title / items | Initial fetch |
| POST /mix/{session_id}/extend | count: 20 | session_id / items / expires_at | Merge on video_id |
| POST /stream | video_id: string | audio.url / video_audio.url | Fetch near playback time |

| API behavior | Implementation |
| --- | --- |
| Base URL | HTTPS only; URL user-info, query and fragment not accepted |
| Headers | Content-Type: application/json; Accept: application/json; X-API-Key |
| Timeout | 90 seconds per POST |
| HTTP non-2xx | ApiFailure with numeric HTTP status |
| Malformed JSON | ApiFailure + user-facing error |
| URL selection | Only https:// URI with authority is playable |

## 7. データモデル仕様

| Model | Fields | Meaning |
| --- | --- | --- |
| MixResponse | sessionId, playlistId, playlistTitle, seedVideoId, items, expiresAt | Playlist session + tracks |
| MixTrack | index, videoId, title, channel, duration, thumbnail, webpageUrl | Per-track display and playback key |
| StreamResponse | videoId, title, audio, videoAudio | Media URL candidates |
| StreamFormat | formatId, ext, protocol, vcodec, acodec, url | HTTPS playable URL |
| PlaybackMode | audio / video | Separate playback pipeline |

`snake_case` JSONとDartのcamelCaseは`fromJson()`で個別対応。`mergeTracks()`はvideo_idをキーとし、先に出現したトラックの順序を保ったまま重複を除外する。

## 8. 連続再生・キュー制御

<!-- URL準備と再生を分離し、Mix表示をURL取得やメディア読み込みで待たせない。 -->
Mix取得成功後は先頭1曲の `/stream` を非同期に開始します。タップ時に同じ実行中要求または有効な結果を使い、準備だけではネイティブプレーヤーを読み込んだり再生したりしません。保持期限は取得完了から60秒と明示URL期限の30秒前の早い方です。停止・Mix再取得・API設定変更で破棄し、失敗・失効時はタップ時に通常取得します。

音声の場合、開始曲のURLを取得した後、**次の2曲分**を `/stream` から順に取得してキューに追加します。再生曲が切り替わるとさらに補充を試みます。Mixの末尾へ到達すると `/extend` を一度試行します。

- 再生URLには有効期限があります。先読み時点で有効でも再生時に失効する場合があります。
- iOSがバックグラウンドでDart処理の実行を制限すると、API呼び出しやキュー補充が止まることがあります。
- **曲間の完全な無音ゼロ、無制限のバックグラウンド連続再生、URL期限切れ時の自動リカバリーは未保証**です。
- `just_audio_background` は単一 `AudioPlayer` 向け。複雑なバックグラウンドキュー制御を追加する段階では `audio_service` の独自 `AudioHandler` への移行を推奨します。
- 動画モードは `video_player` で順番に再生します。**動画モードのバックグラウンド自動連続再生は対象外**です。
- ユーザーがアプリを強制終了した後、OSの制限を超えて自動再生することはできません。

```text
Mix loaded -> prepare first track URL (no autoplay)
Select track -> reuse preparation or POST /stream; release old player in parallel
Audio: start now -> resolve next 2 -> append -> refill on index change
Video: resolve next at transition; wait for old controller disposal before initialization
Queue tail: call /mix/{session_id}/extend (once per unchanged length)
```

| Condition | Current behavior | Limitation |
| --- | --- | --- |
| Audio start | Resolve selected track; play; fill to 3 queued items | No bulk prefetch of entire Mix |
| Audio next | SeekToNext when available, otherwise rebuild | Refresh not guaranteed |
| Audio previous | At 3s or later restart same track; otherwise previous | At playlist head restart |
| Queue resolution error | Report error; skip the failed track | Retry is not implemented |
| Video end | Trigger next() after completion | Background continuous video excluded |
| Manual extend | Update controller track list; do not reset if growing | Server may return no new tracks |
| Direct URL | Play one supplied HTTPS stream | No automatic next track |

## 9. 設定・保存・セキュリティ

- iPhoneからのAPIアクセスには **HTTPSを必須**にしています。Oracle上の `http://IP:8080` は動作しません。nginx等でTLS終端してから設定してください。
- APIキーはコードに埋め込みません。前の会話に掲載したキーは変更してから使ってください。
- URL・鍵のログ出力は避けています。メディアURLは期限と配信元の制約があり、動作が常に保証されるものではありません。
- このコードは**個人開発の技術検証用**です。動画プラットフォームの利用条件、権利者の許諾、App Storeの審査基準は別途確認してください。

| Key / data | Storage | Policy |
| --- | --- | --- |
| mix_player.api_key | flutter_secure_storage (Keychain on iOS) | Secret; never hardcode or print |
| mix_player.server_url | SharedPreferencesAsync | HTTPS required |
| mix_player.last_mix | SharedPreferencesAsync | Remember last input |
| Signed media URL | Playback memory only | Do not persist or log |
| Mix session_id | In-memory controller | Server lifetime approximately 60 min |

## 10. エラー処理・制限事項

| Event | Implemented handling | Future hardening |
| --- | --- | --- |
| API timeout | After 90s: generic timeout error | Configurable retry/backoff |
| HTTP 401 / 403 / 5xx | Surface numeric HTTP error | Classify authentication vs availability |
| Invalid JSON | Report invalid JSON | Telemetry and redaction |
| No tracks | Raise load failure | Offer fresh Mix request |
| Audio URL missing | Fail start or skip prefetched track | Alternate format selection |
| Media playback failure | Display player error | Re-resolve via /stream |
| Extend failure | Save error and prevent loop at same size | Explicit retry UX |
| Session expiry | No automatic recreation | Re-create playlist and reposition |
| iOS background limit | Plugin + iOS audio mode configured | Long-duration device validation |
| User force quits app | No forced automatic restart | OS policy applies |

**注意:** Windowsで取得したURLがiPhoneのWi-Fiおよび4G/5Gで再生された事実はあるが、Oracle Cloudから取得したURLでの実証は別途必要。

## 11. 検証計画・受入条件

| Test ID | Scenario | Expected result | State |
| --- | --- | --- | --- |
| UT-01 | Decode /mix JSON | Models populated; duration parsed | Source test supplied |
| UT-02 | Decode /stream JSON | audio and video_audio parsed | Source test supplied |
| UT-03 | Merge /extend items | No duplicate video_id; original order | Source test supplied |
| UT-04 | API client request | POST body and X-API-Key present | Source test supplied |
| UT-05 | Reject HTTP base URL | ApiFailure | Source test supplied |
| IT-01 | HTTPS Oracle /mix | 20 items and session_id | Not executed |
| IT-02 | HTTPS Oracle /stream | Fresh playable M4A / MP4 URLs | Not executed |
| IT-03 | iPhone cellular audio | Direct media, no Windows intermediary | Not executed with Oracle |
| IT-04 | 3-track continuous audio | A -> B -> C playback | Not executed on device |
| IT-05 | Background / lock screen | Audio continues; media controls work | Not executed on device |
| IT-06 | Video sequential playback | Foreground video transitions | Not executed on device |
| IT-07 | HTTP 403 and expired URL | Graceful error, no secret leakage | Recovery incomplete |
| IT-08 | Session expires / server restart | Failure surfaced; recreate manually | Recovery incomplete |
| IT-09 | Wi-Fi to cellular switch | Playback outcome documented | Not executed on device |
| IT-10 | Stop / mode switch | Old media resources released | Not executed on device |

**検証状態:** 付属された単体テストのソースは存在するが、この環境で`flutter analyze`・`flutter test`・実機再生は実行できていない。

## 12. ビルド・デプロイ手順

ZIPを展開し、`MixPlayerFlutterStarter` のフォルダで **cmd.exe** を開いて以下を実行します。

```cmd
flutter doctor
setup_windows.bat
```

正常終了時の生成先:

```text
MixPlayerFlutterStarter/
  app_src/
    pubspec.yaml
    analysis_options.yaml
    lib/
      main.dart
      player_app.dart
      models/api_models.dart
      services/api_client.dart
      services/app_settings.dart
      controllers/mix_controller.dart
      controllers/playback_controller.dart
    test/api_models_test.dart
  scripts/configure_platforms.py
  setup_windows.bat
  setup_macos.sh
  mix_player_app/                 <-- flutter createで生成する完成プロジェクト
    ios/
    android/
    lib/
    pubspec.yaml
    test/
```

`setup_windows.bat` は次の処理を行います。

1. `flutter create --platforms=android,ios --project-name mix_player_app --org jp.example` で標準のプラットフォームファイルを生成
2. このZIP内の Dart ソースと `pubspec.yaml` を上書きコピー
3. Python 3 が使える場合、iOS の `UIBackgroundModes=audio` と Android の `AudioServiceActivity` / メディアサービスを自動設定
4. `flutter pub get` と `flutter analyze` を実行

`flutter analyze` で問題が出た場合、そのコンソール出力を共有してください。ここではFlutter SDKがないため **実際のFlutterビルドは未実施**です。

Androidで基本機能をテストする場合:

```cmd
cd mix_player_app
flutter devices
flutter run
```

MacにFlutter SDK・Xcode・CocoaPods・Python 3を入れ、同じZIPを展開して:

```sh
chmod +x setup_macos.sh
./setup_macos.sh
cd mix_player_app
flutter devices
open ios/Runner.xcworkspace
```

Xcodeで `Runner` の `Signing & Capabilities` を開き、`Team` と一意の `Bundle Identifier` を指定します。
Developer Modeなど実機設定が必要な場合はXcodeの指示に従います。

```sh
flutter run
```

無料Personal TeamではiPhone向け開発署名のプロビジョニングが7日で期限切れになります（Xcodeで再署名・再インストールが必要）。アプリ公開は不要ですが無制限使用には別の署名・配布方法の検討が必要です。

Macの `mix_player_app/ios/Runner/Info.plist` で `</dict>` の前に以下を追加してください。

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

Androidの場合は [just_audio_backgroundの設定](https://pub.dev/packages/just_audio_background#android-setup) を参照してください。`scripts/configure_platforms.py` で自動的に設定できます。

## 13. 今後の実装計画・リスク

- Flutter SDKがコンテナ環境にないため `flutter analyze`, `flutter test`, `flutter run` をここでは実行できていません。
- iPhone / Android 実機の再生、バックグラウンド継続、ロック画面操作は要実機確認です。
- URL期限切れ時の復旧・HTTP 403の原因分析・HTTPエラー再試行を追加する余地があります。

| Priority | Issue | Required action |
| --- | --- | --- |
| P0 | Expired or rejected signed URL | Detect failures and fetch a fresh /stream URL |
| P0 | Cloud extraction differs from Windows | Verify iPhone playback of Oracle-generated URL |
| P0 | Background long playback on iOS | Validate 3+ tracks under lock screen and cellular |
| P1 | Expired server session | Recreate /mix and restore track selection |
| P1 | Queue fill reliability | Retry policy, bounded concurrency, stable index mapping |
| P1 | Credential rotation | Replace previously exposed API key; TLS termination |
| P2 | Playback state restore | Persist non-secret queue metadata and selected mode |
| P2 | Extensive background control | Evaluate custom audio_service AudioHandler |
| P2 | Legal/operational compatibility | Review content usage terms and distribution requirements |

## 14. ソース対応表・更新履歴

| SwiftUI版 | Flutter版 | 用途 |
|---|---|---|
| `MixPlayerApp.swift` | `lib/main.dart` | 起動・音声セッション初期化 |
| `ContentView.swift` | `lib/player_app.dart` | 画面、URL入力、曲一覧、ミニプレーヤー |
| `MixViewModel.swift` | `lib/controllers/mix_controller.dart` | Mix一覧・セッション・延長 |
| `PlaybackManager.swift` | `lib/controllers/playback_controller.dart` | 再生キュー、音声・動画の切替 |
| `APIClient.swift` | `lib/services/api_client.dart` | POST /mix, /stream, /extend |
| `APIModels.swift` | `lib/models/api_models.dart` | JSONモデル |
| `ServerSettings.swift` | `lib/services/app_settings.dart` | HTTPS設定保存 |
| `KeychainStore.swift` | `flutter_secure_storage` | iOS KeychainでAPIキー保存 |
| `Info.plist` | `scripts/configure_platforms.py` | バックグラウンド音声等の設定 |

**更新履歴:** 2026-10-09 / v0.1 / Flutterスターターソースに対応した初版仕様書を作成。
