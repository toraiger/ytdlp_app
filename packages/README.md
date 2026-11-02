# 再利用用スキルの配布

[flutter-ios-unsigned-ipa.zip](flutter-ios-unsigned-ipa.zip) は、別のFlutterプロジェクトへ持ち運べるCodexスキルです。GitHubでZIPを開き、Download rawから取得できます。隣の `.sha256` ファイルで照合できます。

原本と導入手順は [.agents/skills/flutter-ios-unsigned-ipa](../.agents/skills/flutter-ios-unsigned-ipa/README.md) にあります。ZIPのルートは `flutter-ios-unsigned-ipa/` で、個人共通の `~/.agents/skills/` または別リポジトリの `.agents/skills/` に展開します。

原本を更新したら、リポジトリのルートで再生成し、ZIPと照合ファイルも同じコミットへ含めます。

```bash
python3 scripts/package_ipa_skill.py
```

梱包するファイルはスクリプトで列挙しています。ビルド済みIPA、キャッシュ、認証情報、リポジトリのGit情報は含めません。ZIPはこの小さなスキルパッケージをGitHubから取得できるようにGit管理します。
