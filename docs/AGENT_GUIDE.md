# AGENT_GUIDE — OneClip

AI エージェント向けの使い方メモ。このファイルが、OneClip を機械から使うときの正本である。
操作の棚卸しと人間専用操作の判断は `docs/AGENT_OPERATIONS.md` が正本。

## アプリの目的（1行）

画面の必要な部分だけを範囲選択してクリップボードへコピーし、最大 4 枚を 1 枚の PNG にまとめて注釈を付けられる、ローカル完結の macOS スクリーンショットツール。

## 到達レベル

- レベル: **L1（読み取り可能）＋ 保存データ管理の書き込み**
- 読み取り: 可（状態・保存画像・設定・履歴・点検・検証）
- 操作: 一部可（保存画像の書き出しと隔離削除のみ。撮影・収集・注釈は人間専用 — 理由は `docs/AGENT_OPERATIONS.md`）
- 検証: 可（`verify`、ドライラン、決定的なテスト fixture）

撮影が機械化できない理由: 画面収録許可（TCC）は GUI アプリのプロセスに紐づき許可ダイアログは人間にだけ出ること、範囲選択は人間のドラッグそのものであること、撮影系の Coordinator は GUI セッション内の状態で動くこと。

## 最初に読むもの

- 機械可読な目録: `docs/agent-manifest.json`
- スキーマ版数: 1
- CLI 本体: `Tools/OneClipAgent/`（SwiftPM パッケージ。Xcode プロジェクトには含まれず、アプリ本体のビルドに影響しない）

## 使い方の基本

```bash
# ビルド
cd Tools/OneClipAgent && swift build -c release
BIN=.build/release/oneclip-agent

# 対象データの場所（--root は Library 相当フォルダを指す）
# 既定: ~/Library （実データ）。テストでは必ず --root <試験用フォルダ> を付ける
$BIN status --json
```

- 出力は既定で JSON（成功・失敗とも 1 つの包み）。人間向け整形は `--human`。
- 読み取りコマンドは副作用を持たない。履歴ファイルへ書くのは書き込み系コマンドだけ。
- 画像のバイト列はどのコマンドでも出力しない。扱えるのはメタデータと、明示的な `export` によるファイルコピーだけ。

## コマンド一覧

| コマンド | 種別 | 説明 | 例 |
|---|---|---|---|
| `status` | 読み取り | 版数・保存先・保存件数と容量・設定ドメインの有無・履歴の有無 | `oneclip-agent status --json` |
| `list` | 読み取り | 保存画像の一覧（安定 ID・種別・日時・バイト数） | `oneclip-agent list --json` |
| `get <id>` | 読み取り | 1 件の詳細（パスと PNG 署名の検査結果を含む） | `oneclip-agent get <UUID> --json` |
| `settings list` | 読み取り | 既知の設定キーと値（`--bundle-id` でドメイン切替、既定 `local.OneClip`） | `oneclip-agent settings list --json` |
| `settings get <key>` | 読み取り | 1 キーの値。二進値は有無とバイト数だけ返す | `oneclip-agent settings get OneClip.hasSeenWelcome --json` |
| `history` | 読み取り | この CLI が実行した書き込み操作と成否・失敗理由（`--limit n`） | `oneclip-agent history --json` |
| `doctor` | 読み取り | 保存先・読み取り可否・設定ドメイン・確認できない項目の一覧 | `oneclip-agent doctor --json` |
| `verify` | 読み取り | 保存データの整合性（ファイル名文法・PNG 署名・リンク混入） | `oneclip-agent verify --json` |
| `export <id> --to <dir>` | 書き込み | 保存画像を指定フォルダへコピー（上書きしない） | `oneclip-agent export <UUID> --to ~/out --dry-run` |
| `delete <id> --yes` | 書き込み（破壊的・復元可能） | 保存画像を `Captures/.trash/` へ移動。`--yes` 必須 | `oneclip-agent delete <UUID> --yes` |
| `seed` | 書き込み（テスト専用） | 決定的な fixture を試験用ルートに作る。本番ルートでは拒否 | `oneclip-agent seed --root /tmp/oc-test` |
| `reset --test-data` | 書き込み（テスト専用） | seed した試験用ルートを初期化。seed の目印が無いルートでは拒否 | `oneclip-agent reset --test-data --root /tmp/oc-test` |

共通フラグ: `--json`（既定）/ `--human` / `--root <dir>` / `--timeout <sec>`（既定 30）/ `--dry-run`（書き込み系）/ `--yes`（破壊的操作の確認）/ `--idempotency-key <key>`（書き込み系。再実行しても二重に実行せず最初の結果を返す）/ `--help`（各コマンドにもある）。

未対応の組み合わせは黙って無視せずエラーになる（例: 未知のフラグは `invalid_input`）。

## MCP

MCP 未対応。CLI を使うこと。将来対応する場合は stdio 型の薄いラッパーで、ツール名はコマンド名と 1 対 1 にする（`docs/AGENT_OPERATIONS.md` の判断を参照）。

## SDK

SDK 未対応。JSON スキーマと CLI を使うこと。再利用需要が出た時点で別作業として判断する。

## 典型フロー

### 1. 状態を確認してから使う

```bash
oneclip-agent status --json
oneclip-agent list --json
oneclip-agent get <id> --json
```

### 2. 変更する（必ずドライラン first）

```bash
oneclip-agent export <id> --to ~/out --dry-run --json
oneclip-agent export <id> --to ~/out --idempotency-key export-2026-11-24-01 --json
oneclip-agent verify --json
```

削除も同じ作法: `delete <id> --dry-run` → `delete <id> --yes`。削除は完全削除ではなく `.trash/` への移動で、復元は Finder か手作業のファイル移動で行う。

### 3. 失敗したときに調べる

```bash
oneclip-agent history --json        # 直近の書き込みと失敗理由
oneclip-agent doctor --json         # 前提条件の不足
oneclip-agent verify --json         # 保存データ側の破損・混入
```

## 入出力スキーマ

- 成功: `{"ok": true, "data": ..., "meta": {"schema_version": 1, "request_id": "..."}}`
- 失敗: `{"ok": false, "error": {"code": "...", "message": "...", "retryable": false, "details": {...}}, "meta": {...}}`
- 終了コード: 0 成功 / 1 入力誤り / 2 アプリ側失敗 / 3 権限不足 / 4 対象なし
- ID: 保存ファイル名末尾の UUID（小文字）。再利用されない安定 ID
- 日時: ISO 8601（タイムゾーン付き）。ファイル名内の日時は `filename_timestamp` としてそのまま併記する
- `doctor` / `verify` が不合格のときは終了コード 2 で、内訳は失敗の包みの `error.details` に入る

互換を壊す変更はスキーマ版数を上げ、このガイドと `docs/agent-manifest.json` を同じ変更で更新する。

## エラーコード表

| コード | 意味 | 再試行 | 対処 |
|---|---|---|---|
| `invalid_input` | 引数・フラグ・ID 形式の誤り | 不可 | `--help` で形式を確認する |
| `not_found` | 対象の ID・キー・ドメインが無い | 不可 | `list` / `settings list` で実在を確認する |
| `app_failure` | アプリ側の失敗（IO 失敗、`verify` / `doctor` の不合格、上書き競合は `conflict`） | 内容による | `details` の理由を見る |
| `conflict` | 書き出し先に同名ファイルが既にある | 不可 | 別の書き出し先を使う（上書きはしない） |
| `permission_denied` | 保存先などへアクセスできない | 不可 | 対象フォルダの権限を人間が確認する |
| `production_guard` | 本番ルートへの `seed` / `reset` を拒否した | 不可 | `--root` で試験用フォルダを明示する |
| `confirmation_required` | 破壊的操作に `--yes` が無い | 不可 | `--dry-run` で確認してから `--yes` を付ける |
| `timeout` | `--timeout` を超過した | 可 | 保存件数が多い場合は `--timeout` を延ばす |

## 人間専用操作

| 操作 | 理由 | 人間が行う手順 |
|---|---|---|
| 画面収録許可の付与・ダイアログ応答 | OS の TCC ダイアログは本人にだけ出る | アプリの許可画面、またはシステム設定 > プライバシーとセキュリティ > 画面収録 |
| 範囲選択のドラッグ（単発・まとめ撮り） | 撮影対象の指定そのものが身体操作 | ホットキーで撮影を開始し、範囲をドラッグ |
| ホットキーの記録（設定変更） | 実際にキーを押す対話的操作で確定する | 設定画面で対象のキーを押す |
| アップデートの適用 | 置き換えと再起動を伴い本人の同意が前提 | 設定画面の「アップデートを確認…」 |
| 画質・見え方の最終判定 | 身体感覚の判定 | 実機で画像を開いて確認 |
| App Store 提出まわりの操作 | 本人の明示承認が要る別工程 | このガイドの対象外 |

注釈の編集・収集素材の操作・完成コピーは人間専用ではなく「未実装（将来: アプリ内エージェントモード）」である。現時点では GUI で行うこと。一覧は `docs/AGENT_OPERATIONS.md` の操作カタログを参照。

## やってはいけない操作

- 実データのルート（`~/Library`）に対して `seed` / `reset --test-data` を実行しない（CLI 側でも拒否される）。
- 保存フォルダ内のファイルを直接編集・改名しない。ID とファイル名文法が崩れ、`verify` が不合格になる。削除は `delete`（隔離）を使う。
- 出力 JSON に画像内容が含まれると想定しない。画像そのものが必要なら `export` でファイルとして取り出す。
- GUI の操作履歴は存在しない。`history` に出ないことを「GUI で何も起きていない」証拠にしない。
- 画面収録許可の状態を CLI の結果から推測しない。`doctor` は `unknown` と正直に返す。
