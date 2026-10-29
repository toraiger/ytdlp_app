# Mix Player

[機能仕様書 v0.1](docs/specification.md)に基づく Flutter アプリです。iPhone を主対象とし、Android でも利用できます。既存の FastAPI から Mix と再生 URL の JSON を取得し、メディア本体には端末から HTTPS で直接接続します。

[画面サンプル（テスト音源）](docs/screenshots/player.png)

## 実装した機能

- HTTPS API URL と X-API-Key の設定。API キーは iOS Keychain / Android の安全なストレージに保存します。
- YouTube Mix の20曲取得、サムネイル・タイトル・チャンネル・長さの表示。
- 手動・末尾での追加取得と、video_id による重複排除。
- 音声の連続再生。現在の曲と次の2曲分を解決し、曲が切り替わると先読みを補充します。
- 一覧取得後に先頭曲の音声を読み込み、タップ後に再生開始。準備中のタップも同じ処理を引き継ぎます。
- 一覧タップ・前後の曲への移動で有効なキューを再利用。URL とメディア用ヘッダーを最大5分・16曲分だけメモリに保持します。
- フォアグラウンドの動画＋音声再生。
- 再生・一時停止・前後の曲・停止・シーク、HTTPS メディア URL の直接再生テスト。
- 最後に取得した Mix URL の復元、エラー表示、音声のメディア通知・ロック画面操作用設定。

バックエンドのソースはこのリポジトリに含みません。API URL とキーはアプリ内の「API サーバー設定」から入力してください。実在する接続先やキーはソース・コミットに含めないでください。

## 開発環境

Flutter 3.32.5 / Dart 3.8.1 を使用します。直接依存は仕様書のバージョンを固定し、推移的依存は pubspec.lock に保存しています。Android は API 24（Android 7.0）以上、iOS は 13.0 以上です。Android のビルドには SDK 34〜36（依存プラグインが使用）、Build Tools 35 / 36、NDK 27.0.12077973、JDK 17 または21を使用します。

~~~bash
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter devices
flutter run
~~~

既に iOS / Android のプロジェクトとプラグイン設定を用意しています。生成し直した場合に限り、次のコマンドでバックグラウンド音声・Keychain・Android メディアサービスを再設定できます。

~~~bash
python3 scripts/configure_platforms.py
~~~

## iPhone にインストール

Mac に Flutter、Xcode、CocoaPods を用意してください。

~~~bash
flutter pub get --enforce-lockfile
cd ios
pod install
cd ..
open ios/Runner.xcworkspace
~~~

Xcode の Runner → Signing & Capabilities で Apple Account の Team と一意の Bundle Identifier を設定し、iPhone を接続して flutter run を実行します。UIBackgroundModes=audio と Keychain 用 entitlements は設定済みです。署名設定・端末の Developer Mode は利用する Apple Account と端末に合わせて設定してください。

### GitHub Actions で署名なし IPA を作成

Actions の **iOS unsigned IPA** を開き、Run workflow から対象のブランチを選んで実行できます。作業ブランチを含め、iOS のソースやビルド設定を push した場合も実行します。macOS 15 / Xcode 16.4 / Flutter 3.32.5 で次のビルドを行い、iPhone 用の arm64 アプリを Payload/Runner.app の形式で IPA にまとめます。

~~~bash
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --no-pub
~~~

成功した実行の Artifacts から **mix-player-ios-unsigned-ipa** をダウンロードし、ZIP 内の **MixPlayer-unsigned.ipa** を取り出してください。SHA-256 の確認用ファイルも含みます。Apple の証明書や署名用 Secrets は不要です。

この IPA は SideStore や Sideloadly で自分の Apple Account を使って再署名してインストールします。無料アカウントの署名期限は7日間で、継続利用には更新が必要です。署名なしの IPA を iPhone で開くだけではインストールできません。iOS の Bundle Identifier は jp.toraiger.mixPlayerApp です。実機でのインストールと音声再生は別途確認してください。

## Android にインストール

Android SDK とエミュレーター、または USB デバッグを有効にした端末を用意します。

~~~bash
flutter run -d <device-id>
flutter build apk --debug --no-pub
flutter build apk --release --no-pub
~~~

APK の生成先は build/app/outputs/flutter-apk/ 内の app-debug.apk と app-release.apk です。app-release.apk はリリースモードで最適化されますが、現時点ではテスト用の鍵で署名します。ストア配布用の独自署名鍵は未設定です。

GitHub Actions の Flutter checks でも両方をビルドします。GitHub にログインして成功した実行の Artifacts から mix-player-debug-apk または mix-player-release-apk をダウンロードし、ZIP 内の APK を取り出してください。Actions の Run workflow から手動で再ビルドすることもできます。

## API 契約

| エンドポイント | JSON ボディ | 使用する応答 |
| --- | --- | --- |
| POST /mix | url, count=20 | session_id, playlist_title, items |
| POST /mix/{session_id}/extend | count=20 | session_id, items |
| POST /stream | video_id | audio.url, video_audio.url |

`audio.http_headers` と `video_audio.http_headers` は、それぞれの再生 URL に付けるメディア用 HTTP ヘッダーです。現在の曲・音声の先読み・動画再生で維持します。API 認証の `X-API-Key` はメディア配信先に送りません。音声は just_audio のネイティブヘッダー実装を使うため、ローカル HTTP プロキシ用の通信許可は不要です。

各 POST に Content-Type、Accept、X-API-Key を付与し、90秒でタイムアウトします。API のベース URL は HTTPS のみで、認証情報・クエリ・フラグメントを拒否します。API リダイレクトを自動追跡せず、鍵を別の接続先へ転送しません。期限付きメディア URL とセッション ID はメモリ上だけで保持します。

同じ曲への `/stream` 呼び出しが重なった場合は結果を共有します。URL の `expire` が分かる場合は期限の30秒前から再利用せず、分からない場合も取得から5分でキャッシュを失効させます。API 設定を変更するとキャッシュも破棄します。再利用した音声の読み込み・再生に失敗した場合は1回だけ新しいURLを取得します。サーバーのAPI契約を変更する必要はありません。

### Raspberry Pi / Tailscale API で確認する

1. iPhone の Tailscale をオンにし、Safari から API の `/health` に接続できることを確認します。
2. アプリ右上の「API サーバー設定」で、`https://pi.xxxxx.ts.net` のようなベース URL と API キーを保存します。URL の末尾に `/health` や `/stream` は付けません。
3. YouTube Mix URL を入力し、「Mix を20曲取得」をタップします。「音声のみ」を選び、曲をタップして再生します。
4. 「動画＋音声」に切り替え、曲を選び直して動画も確認します。有効なURLを再利用できる場合はAPIへの再問い合わせを省き、対応するヘッダーを渡します。
5. まずラズパイと同じ Wi-Fi で確認し、その後 iPhone をモバイル回線へ切り替えて確認します。回線切り替え後は曲を選び直してください。

API の JSON 取得と、iPhone からメディア配信元へのアクセスは別の通信です。ラズパイで取得した URL であっても、メディア本体は iPhone から直接取得します。配信元の IP 制約や有効期限による再生失敗は、実機で切り分けます。

## クラウドでの開発

クラウドの既存チェックアウト /workspace/ytdlp_app を使います。タスクは既に分離されているので、Git worktree の作成は不要です。

~~~bash
bash scripts/setup_cloud.sh
bash scripts/flutterw analyze --no-pub
bash scripts/flutterw test --no-pub
bash scripts/flutterw build web --no-pub --no-web-resources-cdn
~~~

Android ビルド環境も準備する場合:

~~~bash
python3 scripts/install_jdk.py
python3 scripts/install_android_sdk.py
bash scripts/flutterw build apk --debug --no-pub --target-platform android-arm64
~~~

Flutter SDK とキャッシュはチェックアウト外の /workspace/.tooling と /workspace/.cache に配置します。書き込み不可のホームディレクトリを変更する必要はありません。

Web は画面とコンパイルの検証用です。ブラウザーから実際の API に接続するには、その API が CORS を許可している必要があります。iPhone / Android の通信はブラウザーの CORS 制約を受けません。

## 検証と現在の範囲

テストは JSON 変換、API リクエスト、HTTPS 制約、応答の秘匿、Mix の追加・競合、先読み・スキップ、停止時の競合、動画の解放、設定ダイアログ、狭い画面の表示を確認します。実行結果は [検証記録](docs/validation.md) に記載します。

再利用した音声URLの失敗時は1回だけ自動再取得します。期限切れ Mix セッションの自動再作成と、再生キュー・位置の永続化は未実装です。Mixのセッションが失効した場合は一覧を再取得してください。長時間のバックグラウンド再生、実API、iPhone のロック画面・通信回線切り替えは実機での検証が必要です。
