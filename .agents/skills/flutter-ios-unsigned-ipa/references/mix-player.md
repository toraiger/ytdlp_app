# Mix Playerで確認済みの構成

対象リポジトリが `toraiger/ytdlp_app` の場合の参考資料です。他のアプリでは、そのプロジェクトの設定を調べてください。以下の固定値を汎用の既定値にしないでください。

| 項目 | 確認済みの値・参照先 |
| --- | --- |
| ワークフロー | `.github/workflows/ios.yml` / `iOS unsigned IPA` |
| ランナー | macOS 15 |
| Xcode | 16.4。`DEVELOPER_DIR` はワークフローを参照 |
| Flutter | 3.32.5。`.flutter-version` とワークフローを参照 |
| ビルドスクリプト | `scripts/build_app.sh` |
| iOS Bundle ID | `jp.toraiger.mixPlayerApp` |
| 成果物名 | `mix-player-ios-unsigned-ipa` |
| IPA名 | `MixPlayer-<version>-<build>-<short SHA>-unsigned.ipa` |
| 添付ファイル | `<IPA名>.sha256`、`BUILD-INFO.txt` |

## ビルド

```bash
flutter pub get --enforce-lockfile
bash scripts/build_app.sh ios --release --no-codesign --no-pub
```

`build_app.sh` は `pubspec.yaml` のバージョンを読み、OSのメタデータと画面表示へ同じ値を渡します。GitHub Actionsでは `MIX_BUILD_NUMBER` に実行番号、`MIX_APP_REVISION` にソースSHAを渡します。環境変数を与えないローカルビルドは、pubspecのビルド番号と現在のGitコミットを使います。

メイン実行ファイルは `build/ios/iphoneos/Runner.app/Runner`。包装時に `Payload/Runner.app` へコピーし、`zip -r -y` でIPA化します。Appleの証明書・プロビジョニング用Secretsは使用しません。

## 成果物の検証と更新確認

- 期待する版番号はpubspec、ビルド番号は実行の `run_number`、コミットは実行の `head_sha` と照合します。
- `BUILD-INFO.txt` の `Version` / `Build` / `Commit` を同じ情報と比較します。
- このアプリでは `UIBackgroundModes` に `audio` が必要です。これは汎用検証ツールの必須条件ではなく、Mix Player固有の確認項目です。
- 画面上部に版番号・ビルド番号、APIサーバー設定画面に短いコミット番号を表示します。
- 更新時は同じApple Accountで新しいIPAを取り込みます。アプリの削除を更新手順に含めません。

過去の検証例は `0.1.2 / build 11 / dd82d76` です。今後のビルド対象として固定せず、依頼時点のブランチ・SHA・設定を確認してください。
