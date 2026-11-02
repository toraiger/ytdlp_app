# Flutter iOS Unsigned IPA

GitHub ActionsのmacOSランナーでFlutterアプリの署名なしIPAを作り、検証して渡すためのCodexスキルです。他のFlutterアプリにも利用できます。

## 個人共通スキルとして導入する

配布ZIPの中身は次の形です。

```text
flutter-ios-unsigned-ipa/
  SKILL.md
  README.md
  references/
  scripts/
```

macOS / Linuxでは、ZIPをダウンロードしたディレクトリで実行します。

```bash
mkdir -p "$HOME/.agents/skills"
unzip flutter-ios-unsigned-ipa.zip -d "$HOME/.agents/skills"
```

Windows PowerShellの場合：

```powershell
$ipaSkillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
New-Item -ItemType Directory -Force -Path $ipaSkillsRoot
Expand-Archive -Path .\flutter-ios-unsigned-ipa.zip -DestinationPath $ipaSkillsRoot
```

同名のスキルを導入済みの場合は、既存内容と比較して更新してください。別のプロジェクトだけで使う場合は、そのリポジトリの `.agents/skills/` に同じフォルダを配置できます。同名のスキルを両方の場所に置く必要はありません。

配置した環境の新しいCodexセッションで、次のように呼び出します。

```text
$flutter-ios-unsigned-ipa で、このFlutterアプリのIPAを作って。
```

対象ブランチがある場合は依頼に添えます。スキル一覧へ反映されない場合はCodexを再起動してください。個人共通領域が読み取り専用のクラウド環境では、リポジトリ内のスキルを利用するか、ZIPを手元の環境へ導入します。

## 構成

- `SKILL.md`: 対象の調査、ビルド、取得、検証、案内の手順。
- `references/github-actions.md`: 別のFlutterプロジェクトでも使うコマンドとワークフロー例。
- `references/mix-player.md`: Mix Playerで確認済みの構成。汎用手順の既定値ではありません。
- `scripts/verify_ipa.py`: Python 3標準ライブラリのみで動くIPA検証ツール。
- `scripts/test_verify_ipa.py`: 検証ツールの正常・異常系テスト。

## 検証ツールを単独で使う

```bash
python3 scripts/verify_ipa.py /path/to/App.ipa \
  --expected-bundle-id com.example.anotherApp \
  --expected-version 1.2.3 \
  --expected-build-number 42 \
  --sha256-file /path/to/App.ipa.sha256 \
  --require-checksum
```

上記の識別子と番号は例です。対象プロジェクトの実際の値を指定します。成功時はJSONを標準出力へ返し、検証失敗時は標準エラーへ理由を返して終了コード1となります。隣接する `.ipa.sha256` は自動検出します。照合ファイルがなければSHA-256の計算だけを行い、`checksum_verified: false` として区別します。

この検証ではファイルの展開やアプリの実行を行いません。メインアプリの署名なし状態を確認し、内包する全framework・extensionの署名や端末上の機能を保証するものではありません。

テストは同梱フォルダ内で実行できます。Xcode・Flutter・ネットワークは不要です。

```bash
python3 -m unittest discover -s scripts -p 'test_verify_ipa.py' -v
```
