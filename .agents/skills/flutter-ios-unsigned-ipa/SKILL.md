---
name: flutter-ios-unsigned-ipa
description: Build, retrieve, and verify unsigned iPhone IPA files for Flutter apps using GitHub Actions macOS runners. Use when the user asks for an IPA, a SideStore or Sideloadly build, or the same unsigned iOS build method in another Flutter repository. IPA作成・署名なしiOSビルド・SideStore向け配布の依頼に使う。
---

# Flutterの署名なしIPAを作成する

このスキルは、FlutterアプリをGitHub ActionsのmacOSランナーでビルドし、自己署名ツールで導入できるIPAを渡すための手順です。アプリ名・リポジトリ・Bundle ID・ブランチ・SDK・版番号を固定しません。App Store向けの証明書署名や公開は扱いません。

## 対象と既存設定を確認する

1. ユーザーの指示、適用される `AGENTS.md`、作業ツリーの変更を確認する。対象リポジトリ、ref、リモートのコミットSHAを特定する。ユーザーがrefを指定していなければ現在の作業ブランチを使う。
2. `.github/workflows/`、Flutterの固定バージョン設定、`pubspec.yaml`、iOSのプロジェクト・flavor設定、既存ビルドスクリプトを読む。対象flavor・entrypoint・Bundle IDと期待するバージョンを確認する。発見できる情報をユーザーへ質問しない。
3. 既存のiOSワークフローとビルド番号の採番規則を優先する。SDKや対象アプリを確定できない場合だけ、不足情報を確認する。別プロジェクトからSDKの固定値やBundle IDを流用しない。
4. 作業中の変更は保持する。リモート未反映の変更を含める場合は、セッションで許可された範囲でコミット・pushし、ビルド対象SHAを明示する。

Mix Playerに適用する場合だけ [references/mix-player.md](references/mix-player.md) も参照する。一般的なワークフローの作成・包装・実行例は [references/github-actions.md](references/github-actions.md) にある。

## 対象SHAのIPAを取得する

- `gh` を使う各操作に確認済みの `--repo OWNER/REPO` を指定する。トークンや認証ファイルの内容を表示しない。
- 対象ワークフロー・対象SHAについて、成功済みで有効期限内のIPAがあれば再利用する。「最新」の実行番号だけで成果物を選ばない。
- 新しいビルドが必要なら、既存のpushトリガーによる実行を優先する。該当実行がなければ対象refで `workflow_dispatch` を実行する。同じビルドを重複起動しない。
- 実行の `head_sha` が対象SHAと一致し、ビルドと成果物アップロードが成功したことを確認する。失敗した実行のIPAを完成品として案内しない。
- ネイティブビルドはmacOS/Xcodeで行う。LinuxではGitHub Actionsの起動・確認・ダウンロード・IPA検証を行える。

## ビルドとIPA化

- プロジェクトの固定SDKとlockfileで依存を準備する。既存スクリプトがある場合はそれを使い、flavor・entrypoint・ビルド番号・既存の `--dart-define` を維持する。
- 基本コマンドは `flutter build ios --release --no-codesign --no-pub`。初回の依存解決後に実行する。署名付きexportを必要とする `flutter build ipa` に置き換えない。
- 生成された実機用 `.app` を `Payload/<実際のアプリ名>.app` にコピーし、シンボリックリンクを保ってZIP化する。拡張子を `.ipa` にする。アプリ名を `Runner` と決め付けない。
- 新しく包装処理を用意する場合、ファイル名には実際のバージョン・ビルド番号・短いSHAを付け、SHA-256の照合用ファイルとソースSHAの記録も添える。
- 既存アプリのBundle IDを維持する。画面内の版番号表示に対応しているプロジェクトでは、OSのメタデータと同じ値を渡す。ビルドのためだけにアプリのUIを追加変更しない。

## ダウンロードして検証する

成果物を空の専用ディレクトリに取得し、このスキルに同梱した検証ツールを使う。`SKILL_DIR` は読んでいるこのスキルの実際のディレクトリへ展開する。プロジェクトの `scripts/` にあると仮定しない。

```bash
python3 "$SKILL_DIR/scripts/verify_ipa.py" /path/to/App.ipa \
  --expected-bundle-id PROJECT_BUNDLE_ID \
  --expected-version PROJECT_VERSION \
  --expected-build-number BUILD_NUMBER
```

- Python 3の標準ライブラリのみで実行できる。
- ZIPの整合性、メインアプリのInfo.plist、期待する識別子・版番号・ビルド番号、iPhoneOS用arm64実行ファイル、メイン実行ファイルの署名なし状態を確認する。
- 隣接する `.ipa.sha256` があれば照合する。別の場所の照合ファイルは `--sha256-file PATH` で指定する。照合を必須にする場合は `--require-checksum` を付ける。
- 照合ファイルがない場合もSHA-256を計算するが、出力の `checksum_verified` は `false` となる。計算しただけの値を「照合済み」と報告しない。
- バンドル・版番号・ビルド番号の期待値は、ダウンロードしたIPA自身だけから決めず、対象プロジェクトと実行の設定から取得する。
- `BUILD-INFO.txt` などの記録がある場合は、実行のSHA・ビルド番号とも照合する。スキルの保存・検証だけを依頼された場合は、新しいIPAビルドを起動しない。

## ユーザーへ渡す

- 対象ブランチ・短いSHA・版番号・ビルド番号と、実際に取得できるGitHub Artifactsのリンクを案内する。非公開リポジトリではGitHubへのログインが必要。
- ZIP内のIPAファイル名を伝える。自己署名ツールを使う場合、SideStore/Sideloadlyで再署名する形式であることを説明する。
- アップデートの案内では、新しいIPAを取り込む手順と、プロジェクトに備わる版番号の確認方法を使う。SideStoreのRefreshは既存アプリの署名を更新する操作。
- 実施した検証と端末で確認する項目を区別する。IPAの検証成功を、iPhoneへの導入や実再生の確認済みと扱わない。
