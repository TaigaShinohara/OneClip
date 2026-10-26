# ソース公開の方針

公開先は `TaigaShinohara/OneClip`、対象はソース・テスト・Xcodeプロジェクト・技術文書です。
ライセンスは[MIT](../LICENSE)。著作権表示は `Copyright (c) 2026 TaigaShinohara` です。
一般向けアプリ配布・署名・公証は別工程です。

## 公開する情報

機能、仕様、ビルド・貢献手順、技術的な検証結果と限定条件、未確認事項を記載します。
個人の操作・回答・認証経緯、会話・作業日誌、内部管理リンク・識別子、個人パス、私用環境の詳細を含めません。
実画像、画面・クリップボードの内容、認証情報、署名鍵、ビルド成果物も含めません。
公開するGit著者名・著作権者名は承認された表示に揃え、メールにはGitHub noreplyを使います。

## 公開前の点検

- 全追跡ファイルと到達可能な全履歴を走査し、秘密値・内部参照・個人作業記録・不要生成物を確認する。
- 自動検出に加えて文書を目視確認する。検出値をログへ再掲せず、ファイル・行・分類だけを報告する。
- 相対リンク、文書の整合、変更に影響する試験を確認する。
- コード・Xcode入力が検証済み版と同一なら、ビルド結果を引き継ぐ。異なる場合は資源確認後に再ビルドする。
- 通信・実画面取得・一般pasteboard・権限変更を伴う試験は、許可された範囲でだけ実行する。

初回用の抽出スクリプトはネットワークへ接続せず、クリーンな追跡treeから履歴なしの別repoを作ります。
既存出力は上書きしません。通常の公開後更新で履歴を作り直すためには使いません。

```sh
python3 -m unittest discover -s Tests -p 'PublicSnapshotTests.py' -v
```

## 公開後の照合

GitHubのowner・Public設定・既定ブランチ・SHA・MIT認識・非公開脆弱性報告の有効状態を再取得します。
新規cloneでファイル、実行属性、全履歴、余分なrefs、内部オブジェクトの非継承を確認します。
Release添付、Issue・PR、Actions成果物など、ソース以外の公開面も必要に応じて点検します。

情報の除去が必要な場合は、公開本文の変更だけで履歴からも消えたと判断しません。
旧SHA・raw URL・添付・キャッシュ等のアクセスを確認し、必要ならアクセス制限と別repoへの分離を使います。
第三者の取得済みコピーやサービス内部の完全消去を、確認なしに保証しません。

## コード・素材・名称

外部Swift package、vendored code、同梱画像・フォントはありません。
Apple SDK・OSフォント・SF SymbolsはUI APIから参照し、素材ファイルを再配布していません。
本ソースのMITは、それら自体を再許諾するものではありません。
[AppleのSF Symbols案内](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)を参照してください。
テスト内のApple Libnotify実装リンクは挙動説明の出典です。

OneClipには、[Posidexの製品](https://marketplace.microsoft.com/en-us/product/posidex.oneclip?tab=overview)や
[OneClip – AI Auto Video Maker](https://apps.apple.com/us/app/oneclip-ai-auto-video-maker/id6755240189)などの同名利用があります。
本プロジェクトはこれらと無関係です。商標調査や全法域の非侵害を確認済みとはしていません。
一般向けアプリ配布前の名称確認は残ります。

## 品質判断と通常の更新

先行ソース公開を公開v1の品質合格としません。M4と対象Collection VoiceOverは保留で、別環境のclone→build等も未実施です。
工程・受入条件は[ROADMAP](ROADMAP.md)を参照してください。
通常の変更は公開リポジトリのブランチ・PR・レビュー・mergeで行います。
内部履歴をmergeせず、自動CI・アプリ配布・公証・課金を自動追加しません。
