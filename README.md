# Mix Player

[機能仕様書 v0.1](docs/specification.md)に基づく Flutter アプリです。iPhone を主対象とし、Android でも利用できます。既存の FastAPI から Mix と再生 URL の JSON を取得し、メディア本体には端末から HTTPS で直接接続します。

[画面サンプル（テスト音源）](docs/screenshots/player.png)

## 実装した機能

- HTTPS API URL と X-API-Key の設定。API キーは iOS Keychain / Android の安全なストレージに保存します。
- YouTubeのウェブで選んだ動画を、ページ移動後にアプリで再生。通常動画は単曲、ミックスは連続再生し、ページも再生曲に追従します。
- iPhoneのWebViewログイン、Netscape形式Cookieファイルの取込とAPIへの登録・保存状態確認。
- YouTube Mix の20曲取得、サムネイル・タイトル・チャンネル・長さの表示。
- Mix取得後に先頭曲の音声を事前に読み込み、タップ時に同じ準備を再利用。自動再生はしません。
- 手動・末尾での追加取得と、video_id による重複排除。
- 音声の連続再生。現在の曲と次の2曲分を解決し、曲が切り替わると先読みを補充します。
- 一覧取得後に先頭曲の音声を読み込み、タップ後に再生開始。準備中のタップも同じ処理を引き継ぎます。
- 一覧タップ・前後の曲への移動で有効なキューを再利用。URL とメディア用ヘッダーを最大5分・16曲分だけメモリに保持します。
- iPhoneのAPI通信は標準のURLSessionを使い、対応サーバーではHTTP/2を利用。API設定画面で直近の通信時間を確認できます。
- フォアグラウンドの動画＋音声再生。
- 再生・一時停止・前後の曲・停止・シーク、HTTPS メディア URL の直接再生テスト。
- 再生位置のバーはドラッグ中に移動先を表示し、指を離したときに一度だけシークします。曲が変わった場合は古い操作を破棄します。
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
bash scripts/build_app.sh ios --release --no-codesign --no-pub
~~~

成功した実行の Artifacts から **mix-player-ios-unsigned-ipa** をダウンロードし、ZIP 内の **MixPlayer-バージョン-ビルド番号-コミット-unsigned.ipa** を取り出してください。SHA-256 の確認用ファイルと `BUILD-INFO.txt` も含みます。Apple の証明書や署名用 Secrets は不要です。

この IPA は SideStore や Sideloadly で自分の Apple Account を使って再署名してインストールします。無料アカウントの署名期限は7日間で、継続利用には更新が必要です。署名なしの IPA を iPhone で開くだけではインストールできません。iOS の Bundle Identifier は jp.toraiger.mixPlayerApp です。実機でのインストールと音声再生は別途確認してください。

この手順は再利用できるCodexスキルとして保存しています。[スキルの導入・使い方](.agents/skills/flutter-ios-unsigned-ipa/README.md)と[他の環境向けZIP](packages/flutter-ios-unsigned-ipa.zip)を参照してください。導入した環境では `$flutter-ios-unsigned-ipa` で呼び出せ、他のFlutterアプリにも利用できます。

### アプリを更新したか確認する

新版を入れる際はZIPを展開し、SideStoreの My Apps →「＋」から新しい番号のIPAを選び、これまでと同じApple Accountで上書きインストールします。SideStoreの Refresh はインストール済みアプリの署名を更新する操作です。

画面上部の Mix Player の下にバージョンとビルド番号を表示します。「API サーバー設定」にはコミット番号も表示するため、ZIP内の `BUILD-INFO.txt` と一致すればその版が起動しています。以前のIPAはすべて `0.1.0 (1)` でしたが、今後はGitHub Actionsの実行ごとにビルド番号が増えます。

配布ビルドには `scripts/build_app.sh` を使用し、OSに登録するバージョンと画面表示へ同じ値を渡します。ローカルでは `pubspec.yaml` の番号を使い、`MIX_BUILD_NUMBER` で変更できます。通常の `flutter run` など、ビルド情報を渡さない起動では「開発ビルド」と表示します。

時間表示が一覧や実際の音と合わない場合は、再生中に「API サーバー設定」→「再生情報」を開いてください。「再生情報をコピー」で、アプリの版・一覧とプレーヤーの曲番号・キュー内の曲数・一覧の長さ・プレーヤーが報告した長さと位置をコピーできます。URL・APIキー・曲名・動画IDは含みません。曲の途中で次の曲が流れる場合は、どの音声データと曲番号が報告されているかを切り分けるために使います。

## Android にインストール

Android SDK とエミュレーター、または USB デバッグを有効にした端末を用意します。

~~~bash
flutter run -d <device-id>
bash scripts/build_app.sh apk --debug --no-pub
bash scripts/build_app.sh apk --release --no-pub
~~~

APK の生成先は build/app/outputs/flutter-apk/ 内の app-debug.apk と app-release.apk です。app-release.apk はリリースモードで最適化されますが、現時点ではテスト用の鍵で署名します。ストア配布用の独自署名鍵は未設定です。

GitHub Actions の Flutter checks でも両方をビルドします。GitHub にログインして成功した実行の Artifacts から mix-player-debug-apk または mix-player-release-apk をダウンロードし、ZIP 内の APK を取り出してください。Actions の Run workflow から手動で再ビルドすることもできます。

## YouTubeのウェブから再生

API設定を保存して「YouTubeを開く」を押し、動画を選びます。その動画ページへ移動した後、アプリのプレーヤーで再生します。YouTubeページは表示したままで、下部の操作バーを使えます。

通常の動画は1本、YouTubeのミックスを選んだ場合は20曲取得して連続再生します。Mixの次曲・前曲に合わせてページも移動し、音声／動画のモードはメイン画面の選択を引き継ぎます。[詳しい操作と動作](docs/youtube-web-playback.md)を参照してください。

## YouTubeにログインしてMixを取得

「API サーバー設定」でURLとAPIキーを保存してから「YouTube連携」を開きます。iPhoneではWebViewにログインして「Cookieを取得」、または「Cookieファイルを選択」でNetscape形式のcookies.txtを取り込み、「このサーバーにCookieを登録」を押します。登録後はMixを取得し直してください。

WebViewのログインがGoogleに拒否された場合はファイル取込を利用できます。保存状態のGETはログインの有効性を保証しません。操作・保存範囲・PUT／GET仕様は[YouTube Cookieの登録](docs/youtube-cookie-api.md)を参照してください。

## API 契約

| エンドポイント | リクエスト本文 | 使用する応答 |
| --- | --- | --- |
| POST /mix | url, count=20 | session_id, playlist_title, items |
| POST /mix/{session_id}/extend | count=20 | session_id, items |
| POST /stream | video_id, include_formats=false | audio.url, video_audio.url |
| PUT /youtube/cookies | JSONではなくNetscape形式テキスト | configured, updated_at（任意） |
| GET /youtube/cookies | 本文なし | configured, updated_at（任意） |

`audio.http_headers` と `video_audio.http_headers` は、それぞれの再生 URL に付けるメディア用 HTTP ヘッダーです。現在の曲・音声の先読み・動画再生で維持します。API 認証の `X-API-Key` はメディア配信先に送りません。音声は just_audio のネイティブヘッダー実装を使うため、ローカル HTTP プロキシ用の通信許可は不要です。

各 POST に Content-Type、Accept、X-API-Key を付与し、90秒でタイムアウトします。API のベース URL は HTTPS のみで、認証情報・クエリ・フラグメントを拒否します。API リダイレクトを自動追跡せず、鍵を別の接続先へ転送しません。期限付きメディア URL とセッション ID はメモリ上だけで保持します。

同じ曲への `/stream` 呼び出しが重なった場合は結果を共有します。URL の `expire` / `expires` クエリまたは `/expire/秒数/` が分かる場合は、選択した形式の期限の30秒前から再利用せず、分からない場合も取得から5分でキャッシュを失効させます。API 設定を変更するとキャッシュも破棄します。再利用した音声の読み込み・再生に失敗した場合は1回だけ新しいURLを取得します。`include_formats=false` は全形式一覧を省く指定で、旧APIでは無視されます。

意図的な1秒・0.4秒の待ち時間を設けず、iPhoneのAPI通信を `cupertino_http 2.4.0` のURLSessionへ切り替えています。同じクライアントのセッションを使い回し、サーバーが対応する場合はHTTP/2を自動交渉します。HTTPSとAPIリダイレクト禁止を維持し、HTTPレスポンスをディスクに保存しません。

モバイル回線・Tailscale経由での確認手順は[通信時間の確認](docs/network-performance.md)を参照してください。API設定画面の「直近の API 通信時間」は、先読みも含めて最後に完了した実通信の値です。通信経路とサーバー処理を合わせた時間で、キャッシュの再利用では更新しません。

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
