# OneClip

必要なところを集めて、ひと貼りで伝えるmacOSのメニューバーアプリです。
一箇所をすぐコピーする操作と、複数箇所を一枚にまとめる操作を用意しています。

現在は開発中です。単発コピーとまとめ撮りは実装済みですが、安定性・使いやすさの確認（M4）は未完了です。
一般向けの署名・公証済みアプリは配布していません。
ソースは[MIT License](LICENSE)で提供します。

## できること

- **範囲をコピー**：一つの画面内で範囲を選び、PNGをクリップボードへコピーします。
- **集めてコピー**：1〜4枚を撮影順に縦へ並べ、一枚のPNGとしてコピーします。追加、個別削除、素材の取り直し、完成プレビューに対応しています。
- **任意のショートカット**：単発とまとめ撮りを別々に設定・変更・解除できます。初期値は未設定で、メニューだけでも使えます。
- **キーボードでの範囲調整**：矢印で移動、Shift＋矢印で大きさを調整し、Enterで確定、Escで取り消します。

OCR、注釈、ファイルへの書き出し、ログイン時の自動起動は未実装です。

## 使い方

1. アプリを起動し、メニューバーのOneClipメニューを開きます。
2. 一箇所なら「範囲をコピー」、複数箇所なら「集めてコピー…」を選びます。
3. 初回の案内と、必要に応じたmacOSの画面収録の許可に従って範囲を選びます。単発では範囲確定後にコピーされます。
4. まとめ撮りでは収集パネルで素材と完成画像を確認し、「コピー」を押してから貼り付け先へ移ります。

起動だけでは撮影・許可要求・コピーは行いません。画面収録の設定変更から自動で撮影を再開することもありません。
範囲選択中のEscはコピーせずに取り消します。まとめ撮りの追加・取り直しを取り消した場合は、既存の素材を残します。

設定を開いたまま撮影でき、選んだ範囲に設定画面があれば画像へ含めます。
ショートカットを変更している間は撮影を停止します。候補を確定するか取り消すと再開できます。
設定を含む範囲の取得中に設定窓が移動・閉鎖された場合は、撮影を中止して選び直しを案内します。

## データの扱い

画像、収集セッション、選択範囲、操作履歴をファイルへ保存せず、画面内容をログへ記録しません。
アプリによる通信や画像の外部送信も行いません。保存する設定はショートカットと初回案内の既読状態だけです。
素材はメモリ上に保持し、セッションの終了・破棄で参照を解放します。スリープ、ロック、ユーザー切替、画面構成変更でも収集中の素材を破棄します。

コピーするとmacOSのクリップボードを置き換えます。貼り付け先やOSによるクリップボードの扱いはOneClipの画像保存とは別です。

## 開発環境とビルド

- macOS 14.0以上を対象とするSwiftUI / AppKitアプリ
- Xcode 16以上、Swift 6対応のツールチェーン
- 外部パッケージなし
- Xcodeプロジェクト：`OneClip.xcodeproj`、共有scheme：`OneClip`
- Bundle ID：`local.OneClip`（ローカル開発用の暫定値）

新しいビルドを始める前に、実行中のビルド、メモリ、作業先と一時領域の空き容量を確認します。

```sh
ps -axo pid=,comm= | rg 'xcodebuild|swift-frontend|swift-build|GradleDaemon|ninja'
memory_pressure -Q
df -h . "${TMPDIR:-/tmp}"
```

`rg` の終了コード1は、一致するプロセスがないことを表します。
リポジトリ直下で次を実行すると、Appleアカウントや配布証明書を使わずコンパイルを確認できます。

```sh
ONECLIP_DERIVED_DATA="${TMPDIR:-/tmp}/OneClip-DerivedData"
xcodebuild -project OneClip.xcodeproj -scheme OneClip \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$ONECLIP_DERIVED_DATA" \
  -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

起動確認にはXcodeのRun、または上の `CODE_SIGNING_ALLOWED=NO` を外したローカルのアドホック署名ビルドを使います。
通常のビルドに個人の認証設定は不要です。配布用の署名・公証・正式な識別子は別途準備が必要です。

## 検証状況

Apple SiliconのmacOS環境で限定的に確認しています。
M2「単発alpha」とM3「まとめ撮りbeta」は、記録された版・環境・対象範囲で限定完了しました。
M3の対象Collection VoiceOverは未実証のまま持ち越しています。

M4の追加評価と対象Collection VoiceOverは保留です。個別に報告された不具合は、その依頼の範囲で改善します。
最小対象OSの実機、Intel Mac、全面的なVoiceOver対応、全表示構成・貼付け先、厳密な画質・性能は未確認です。
一部の取得失敗の原因は未確定です。公開文書の整理によって製品の未解決事項が解消したとは扱いません。

検証の根拠と残件は [M0](docs/M0-VERIFICATION.md)、[M1](docs/M1-VERIFICATION.md)、[M2](docs/M2-VERIFICATION.md)、[M3](docs/M3-VERIFICATION.md)、[M4](docs/M4-VERIFICATION.md) を参照してください。
公開の検証要約には技術的な結果・限定条件・失敗・未実証を記載します。

`Tests/` には架空素材や専用pasteboardを使う独立したCLI試験があります。座標計算の最小例は次のとおりです。
コンパイル前には上と同じ資源確認を行います。

```sh
ONECLIP_TEST_DIR="$(mktemp -d -t oneclip-tests)"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -module-cache-path "$ONECLIP_TEST_DIR/module-cache" \
  OneClip/RegionGeometry.swift Tests/RegionGeometryTests.swift \
  -o "$ONECLIP_TEST_DIR/geometry"
"$ONECLIP_TEST_DIR/geometry"
```

実画面や一般クリップボードを使う確認は、架空素材の内部試験と分けて明示的に実行します。
画面・クリップボードの内容を不具合報告やGitへ含めないでください。

設定撮影に関係する架空サービスの回帰試験は `bash scripts/test_settings_capture.sh` で実行できます。
各コンパイル前に実行中ビルド・メモリ・ディスクを確認し、別ビルドがあれば停止します。
実画面取得・画面収録の許可要求・一般クリップボードの操作は行いません。

## 構成と開発への参加

- `OneClip/`：アプリ、範囲選択、取得、コピー、収集パネル、設定
- `Tests/`：CLI試験と架空素材
- [開発計画](docs/ROADMAP.md)：仕様、優先順位、工程、受入条件の正本
- [開発方針](docs/PREPARATION.md)：構成と開発上の前提
- [公開方針](docs/PUBLICATION.md)：公開内容と履歴の点検
- [貢献方法](CONTRIBUTING.md)：開発・不具合報告・Pull Request
- [セキュリティ報告](SECURITY.md)：非公開での脆弱性報告
- [変更履歴](CHANGELOG.md)

公開履歴は、審査済みのソース・テスト・技術文書を起点とします。
更新は公開リポジトリのブランチとPull Requestで行います。

## ライセンス

Copyright (c) 2026 TaigaShinohara。利用・改変・再配布の条件は[MIT License](LICENSE)を参照してください。
