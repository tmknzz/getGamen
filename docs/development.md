# 開発者向けの説明

## ビルドと起動

Xcode本体を選択したMacで実行します（Command Line Toolsだけではビルドできません）。

```sh
scripts/build-app.sh
```

最後に表示される `getGamen.app` を開きます。設定で保存先・形式・JPEG品質を指定してください。画面撮影にはmacOSの画面収録権限が必要です。`scripts/build-app.sh` は開発用で、署名ID未指定時はad-hoc署名です。配布用ビルドは次の節を参照してください。

`scripts/build-app.sh` は `xcodebuild` でビルドします。ショートカットのアクションの情報（App Intents のメタデータ）は、Xcode のビルドでしか作られないためです。

## 配布用 DMG の作り方

キーチェーン内のチーム4PRU2H4FP5のDeveloper ID Application証明書とApp Store Connect APIキーが必要です。スクリプトはチームを確認し、一致しなければ失敗します。`GETGAMEN_SIGN_IDENTITY` は証明書名の全文、`GETGAMEN_NOTARY_KEY` は.p8ファイルのパス、`GETGAMEN_NOTARY_KEY_ID` はKey ID、`GETGAMEN_NOTARY_ISSUER` はIssuer IDです。APIキーファイルはリポジトリ外に置いてください。

```sh
GETGAMEN_SIGN_IDENTITY='Developer ID Application: <名前> (4PRU2H4FP5)' \
GETGAMEN_NOTARY_KEY='/リポジトリ外のパス/<キー名>.p8' \
GETGAMEN_NOTARY_KEY_ID='<Key ID>' \
GETGAMEN_NOTARY_ISSUER='<Issuer ID>' \
scripts/release.sh
```

署名・DMG作成・公証・staple・Gatekeeper確認を行い、`.build/getGamen-<バージョン>-<ビルド番号>.dmg` に出力します。

## 検証

```sh
swift test -Xswiftc -warnings-as-errors
xcodebuild -project getGamen.xcodeproj -scheme getGamen \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode \
  ONLY_ACTIVE_ARCH=YES test
scripts/verify-app.sh /absolute/path/getGamen.app /absolute/path/new-evidence-directory
```

Intel Macではdestinationのarchをホストに合わせてください。UIテストは独立したテストデータを `/private/tmp/getGamen-ui-*` に作成します。実AppKit UIテスト中は他のAppKitテストを同時実行しないでください。ソース追加後は `python3 scripts/generate-xcode-project.py` でXcodeプロジェクトを再生成できます。

終了時は保存完了を待ちます。OSのログアウト・再起動・シャットダウン操作は一度取り消される可能性があり、その場合はgetGamen終了後に再操作してください。このOS経路は未実機検証です。

CLI と MCP の検証手順は [CLI と MCP](automation.md) の「Build and verify」にあります。

## ビルド番号

アプリメニューの「getGamenについて」に `YYYYMMDDAA` 形式のビルド番号を表示します。
日付は日本時間で、同日は `AA → AB → … → AZ → BA → … → ZZ`、翌日は `AA` に戻ります。
採番は Xcode のビルドフェーズが `scripts/stamp-build.py` で1回だけ行い（`scripts/build-app.sh` も Xcode でビルドします）、
`App/Info.plist` に最後の採番を保存します（ビルド後の変更をコミットしてください）。
同一チェックアウト内の並列ビルドはロックで重複を防ぎます。別チェックアウト間では最終採番の同期が必要です。
採番後にビルドが失敗した場合、その番号は再利用しません。
表示用番号は `getGamenBuildNumber`、OS用の数値形式は `CFBundleVersion` に保存します。
採番テスト: `python3 scripts/test-build-number.py`。
