# 汎用のビルド・包装・取得手順

## 既存の設定を使う

まず対象リポジトリのワークフローとビルドスクリプトを読みます。Flutter/Xcodeの固定値、flavor、entrypoint、Bundle ID、ビルド番号の採番を優先してください。既存のアプリ内ビルド情報表示に使われる `--dart-define` も維持します。SideStore用IPAのためにアプリのUIを新設する必要はありません。

ソースrefとSHAを確定し、同じSHAで成功したIPAがあれば期限とメタデータを確認して再利用します。

```bash
gh run list --repo "$ipa_repo" --workflow "$ipa_workflow" \
  --commit "$ipa_sha" \
  --json databaseId,headSha,status,conclusion,url
```

再ビルドが必要で、pushに対応する実行もない場合：

```bash
gh workflow run "$ipa_workflow" --repo "$ipa_repo" --ref "$ipa_ref"
```

開始した実行のIDと対象SHAを照合してから、そのIDの完了と成果物を確認します。

```bash
gh run view "$ipa_run_id" --repo "$ipa_repo" \
  --json headSha,status,conclusion,jobs
gh run watch "$ipa_run_id" --repo "$ipa_repo" --exit-status --interval 20
gh api "repos/$ipa_repo/actions/runs/$ipa_run_id/artifacts"
gh run download "$ipa_run_id" --repo "$ipa_repo" \
  --name "$ipa_artifact_name" --dir "$ipa_download_dir"
```

エージェントからwatchを使う場合は、長時間ブロックせず実行セッションを使って進捗を伝えます。成果物ダウンロード先はその実行専用の空ディレクトリにします。

## ワークフローがないプロジェクト

以下は `.github/workflows/ios-unsigned.yml` として作成する場合の雛形です。`__MACOS_RUNNER__`、`__XCODE_DEVELOPER_DIR__`、`__FLUTTER_VERSION__` は対象プロジェクトの設定に基づく値へ置き換えます。確定できなければ、それに必要な情報だけを確認します。プレースホルダーを含んだまま実行しないでください。別のファイル名を使う場合はpushの対象パスも合わせます。

新規ワークフローを作業ブランチで初めて使う場合はpush実行を利用します。手動実行には、ワークフローがデフォルトブランチ側で認識されている必要があります。

flavorや専用ビルドスクリプトがある場合はbuildステップを合わせます。ビルド番号も既存の採番があれば維持し、配布済みの同じバージョンより小さな番号を新しい版として渡さないでください。

```yaml
name: iOS unsigned IPA
on:
  workflow_dispatch:
  push:
    paths:
      - '.github/workflows/ios-unsigned.yml'
      - '.flutter-version'
      - '.fvmrc'
      - 'ios/**'
      - 'lib/**'
      - 'assets/**'
      - 'pubspec.yaml'
      - 'pubspec.lock'
permissions:
  contents: read
jobs:
  ios:
    runs-on: __MACOS_RUNNER__
    timeout-minutes: 35
    env:
      DEVELOPER_DIR: __XCODE_DEVELOPER_DIR__
      COCOAPODS_DISABLE_STATS: 'true'
      IPA_BUILD_NUMBER: ${{ github.run_number }}
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - run: xcodebuild -version
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '__FLUTTER_VERSION__'
          channel: stable
          cache: true
      - run: flutter pub get --enforce-lockfile
      - name: Build unsigned iPhone app
        run: flutter build ios --release --no-codesign --no-pub --build-number="$IPA_BUILD_NUMBER"
      - name: Package IPA
        shell: bash
        run: |
          set -euo pipefail
          ipa_apps=(build/ios/iphoneos/*.app)
          if [[ ${#ipa_apps[@]} -ne 1 || ! -d "${ipa_apps[0]}" ]]; then
            printf '%s\n' 'Expected one device app; check the selected target/flavor.' >&2
            exit 1
          fi
          ipa_app=${ipa_apps[0]}
          ipa_app_name=$(basename "$ipa_app")
          ipa_plist="$ipa_app/Info.plist"
          plutil -lint "$ipa_plist"
          ipa_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ipa_plist")
          ipa_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ipa_plist")
          ipa_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ipa_plist")
          ipa_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ipa_plist")
          test "$ipa_build" = "$IPA_BUILD_NUMBER"
          xcrun lipo "$ipa_app/$ipa_executable" -verify_arch arm64
          ipa_filename="App-${ipa_version}-${ipa_build}-${GITHUB_SHA:0:7}-unsigned.ipa"
          mkdir -p build/ios/ipa/Payload
          ditto "$ipa_app" "build/ios/ipa/Payload/$ipa_app_name"
          cd build/ios/ipa
          zip -q -r -y "$ipa_filename" Payload
          zip -T "$ipa_filename"
          shasum -a 256 "$ipa_filename" > "$ipa_filename.sha256"
          printf 'Bundle ID: %s\nVersion: %s\nBuild: %s\nCommit: %s\n' \
            "$ipa_bundle_id" "$ipa_version" "$ipa_build" "$GITHUB_SHA" > BUILD-INFO.txt
      - uses: actions/upload-artifact@v4
        with:
          name: ios-unsigned-ipa
          path: |
            build/ios/ipa/*.ipa
            build/ios/ipa/*.ipa.sha256
            build/ios/ipa/BUILD-INFO.txt
          if-no-files-found: error
```

アプリ名やflavorに応じて生成先が違う場合は、実際の出力を指定します。署名後のインストールを確認していなければ「実機で動作確認済み」と報告しません。

## 配布リンク

APIが返す実在するartifact IDを使って、次の形式で案内します。

```text
https://github.com/OWNER/REPO/actions/runs/RUN_ID/artifacts/ARTIFACT_ID
```

外側のZIPと内側のIPAを区別し、期待する版番号とIPAファイル名も伝えます。成果物が期限切れの場合は、対象SHAを確かめて再ビルドし、期限切れリンクを再利用しないでください。
