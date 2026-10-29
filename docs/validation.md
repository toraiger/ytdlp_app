# 検証記録

検証日: 2026-10-13。Linux クラウド環境、Flutter 3.32.5 / Dart 3.8.1 を使用。

## 完了した検証

| 確認 | 結果 |
| --- | --- |
| flutter pub get --enforce-lockfile | 成功。仕様書の直接依存8パッケージを固定 |
| flutter analyze --no-pub | No issues found |
| flutter test --no-pub | 36件すべて成功（単体31件・画面5件） |
| 日本語フォント同梱後の画面テスト | 5件すべて成功。320px幅でも overflow なし |
| Dart フォーマット検査 | 14ファイル、変更不要 |
| flutter build web --no-pub --no-web-resources-cdn | 成功 |
| flutter build apk --debug --no-pub --target-platform android-arm64 | 成功。Android 7.0 以上の arm64 端末向け debug APK |
| iOS / Android 設定 | plist・entitlements・manifest を検査。再実行でも設定重複なし |
| クラウドの準備スクリプト | Flutter キャッシュ準備と固定 lockfile での依存導入が成功 |

## ブラウザーでの機能確認

Chromium / Playwright を使い、ビルドした実際の Flutter Web アプリを操作しました。API は HTTPS 宛てのリクエストをテスト用 JSON 応答へ置き換え、メディアは FFmpeg で生成した12秒の AAC / H.264 ファイルを使用しています。

- API URL とキーを設定画面から保存し、Mix を取得。
- POST のボディと X-API-Key を確認。メディア配信先へのリクエストにはキーが付いていないことも確認。
- 音声の再生時間が進み、A → B → C の3曲が自動で連続再生。
- 次の曲への移動、停止、現在の曲の表示を確認。
- MP4 の再生時間が進み、動画終了後に次の曲へ自動移行。
- 停止後に動画要素が解放され、JavaScript の pageerror が0件。

[画面サンプル](screenshots/player.png)はテスト音源による表示です。

## ブラウザー確認の再現

クラウドには Chromium、Python Playwright、FFmpeg が用意されています。以下をリポジトリのルートで実行し、HTTP サーバーは別のターミナルで起動してください。

~~~bash
bash scripts/flutterw build web --no-pub --no-web-resources-cdn
python3 -m http.server 8080 --bind 127.0.0.1 --directory build/web
~~~

~~~bash
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=440:duration=12 -c:a aac -b:a 96k /tmp/mix-smoke.m4a
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=0x132234:s=320x180:d=12 -f lavfi -i sine=frequency=440:duration=12 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest -movflags +faststart /tmp/mix-smoke.mp4
python3 scripts/smoke_web.py
~~~

生成済みのテスト音源を作り直す場合は FFmpeg に -y を追加してください。スモークテストの API キーは公開のテスト用文字列です。実際の接続先や鍵をテストコードへ記載しないでください。

## 実機で確認する項目

以下はまだ実行していません。

- Oracle Cloud の実 API に対する /mix、/stream、/extend。
- iOS ビルド・署名・インストール（Mac / Xcode と Apple Account が必要）。
- iPhone / Android 実機の音声・動画、バックグラウンド再生、ロック画面操作。
- Wi-Fi / 携帯回線の切り替え、長時間再生、実際の署名付き URL の配信元制約。
- GitHub Actions のワークフロー実行、新しいクラウドタスクでの復元。

URL・セッションの期限切れの自動復旧、再生位置・キューの永続化は仕様書の拡張候補として未実装です。

## 2026-10-28 音声の曲切り替え表示

ネイティブプレーヤーが次の曲を開始する通知が、先読みキューへの追加完了より先に届く条件を単体テストで再現しました。旧実装はその通知を無視し、実際は2曲目でも現在曲の表示が1曲目のまま残ります。

修正後は、曲番号・再生位置・長さをプレーヤーの現在の状態からまとめて取得します。先読みキューへの追加後にも再同期し、通知の順序によって表示が取り残されることを防ぎます。

- 追加処理中に次の曲へ進んでも、曲名と時間が追従することを単体テストで確認。
- 連続する曲の長さが異なる場合も、同じ場合も、次の曲の再生位置が0に戻ることを確認。
- 画面テストで、1曲目の04:24から2曲目の00:00 / 04:23への表示更新を確認。

Flutter 3.32.5 で静的解析は No issues found、全44件のテストが成功しました。Dart のフォーマット検査も成功しています。

## 2026-10-29 初曲URLの事前準備

<!-- モックによる待ち合わせ順序の検証と、Pi・iPhoneでの実時間測定は区別する。 -->
Mix応答後に先頭1曲のURLだけを準備し、一覧表示と設定保存はその完了を待ちません。事前取得済み・取得中の先頭曲をタップした際の要求共有、音声・動画それぞれのHTTPヘッダーの維持、自動再生が発生しないことを確認しました。

- 取得完了から60秒、クエリまたはHLSパスの期限の30秒前で失効する境界を、時計を差し替えて検証。
- 準備失敗、停止、同じセッションIDのMix再取得、API設定変更、別曲選択後の遅い応答を検証。
- 旧プレーヤーの終了待ち中にもURLを取得し、新プレーヤーは両方の完了を待つことを確認。動画を続けて選び直した場合も解放完了を共有して待機。
- URL準備中でも一覧を操作できることと、タップ後にのみ再生が始まることを画面テストで確認。
- Flutter 3.32.5 / Dart 3.8.1：全64テスト成功、静的解析 No issues found。

バックエンドは `feat/raspberry-pi-tailscale` の別作業ツリーで検証しました。抽出共有・別IDの並行取得・取消・失敗後の再試行・認証・全形式の省略・音声形式・ログ秘匿の関連12テストが成功しました。Linux向け設置テストはWindows上で1失敗・23エラーとなり、変更前HEADを一時展開したテストでも同じ結果でした（`os.geteuid` とPOSIXファイル権限の差異）。

### 実機での比較手順

同じPi・iPhone・回線・Mix・先頭曲を使用し、初回取得と繰り返し取得を分けて変更前後を比較します。一覧表示直後のタップと、数秒待ってからのタップも分け、各条件を5回程度測定して中央値と範囲を残します。

| 計測ログのphase | 計測区間 |
| --- | --- |
| `mix_response` | Mix要求開始からJSON解析完了まで |
| `stream_response` | URL要求開始からJSON解析完了まで。事前取得・次曲先読みも対象 |
| `player_load` | 旧プレーヤー終了後の音声loadまたは動画initialize |
| `tap_to_progress` | 再生要求から、再生中かつ位置が初めて0より進む通知まで |
| `stream_extraction`（Pi側） | 抽出スレッドへの依頼から完了まで。共有された抽出につき1回 |

`tap_to_progress` はプレーヤー通知を使う代理指標で、実際に音が聞こえる時刻は実機で確認します。変更前アプリにはこのログがないため、タップから発音までは同じ方法で画面・音声を記録して比較します。ログにはphaseと経過ミリ秒だけを記録し、URL・動画ID・鍵は含めません。

Piへの反映、同じ曲・回線での変更前後比較、iPhone実再生は未実施です。APKビルドとgradlewは全体指示に従って実行していません。

この検証にはテスト用のプレーヤーを使っています。報告された iPhone 実機での表示がこの修正で改善するかは、実機での確認が必要です。
