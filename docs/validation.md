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
