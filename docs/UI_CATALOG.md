# UIカタログ：OneClip

- 最終更新：2026-11-16
- アート方針：`docs/ART_DIRECTION.md` の版 1.0 に準拠

## パーツ一覧

| パーツ名 | 役割 | 正本の場所（コード） | 状態 |
| --- | --- | --- | --- |
| `OneClipTone` | 色の役割定義（`single`, `collection`, `neutral`, `warning`） | `OneClip/OneClipStyle.swift` | 使用中 |
| `OneClipBadge` | トーン色グラデーション円背景のアイコンバッジ | `OneClip/OneClipStyle.swift` | 使用中 |
| `OneClipHeading` | バッジ＋見出し＋サブタイトルの画面ヘッダー | `OneClip/OneClipStyle.swift` | 使用中 |
| `OneClipCard` (`.oneClipCard()`) | 連続角丸 20pt の標準カードコンテナ | `OneClip/OneClipStyle.swift` | 使用中 |
| `OneClipWindow` (`.oneClipWindow()`) | 余白 28pt の標準ウィンドウコンテナ | `OneClip/OneClipStyle.swift` | 使用中 |
| `CaptureDataNotice` | 保存先とクリップボード扱いの共通注記 | `OneClip/NativeCaptureInterface.swift` | 使用中 |
| `ShortcutKeycaps` | ショートカットキーのキートップ表示 | `OneClip/CaptureSettings.swift` | 使用中 |
| `AppUpdateSettingsSection` | 設定画面内の手動アップデート確認セクション | `OneClip/AppUpdateViews.swift` | 使用中（`.oneClipCard()` へ統一） |
| `CaptureResultView` | 撮影後の右下フローティング小画像プレビュー | `OneClip/CaptureResultController.swift` | 使用中（`.continuous` 角丸・高コントラスト対応へ統一） |
| `CollectionPanelView` | まとめ撮り（1〜4枚）の編集・合成パネル | `OneClip/CollectionPanel.swift` | 使用中 |
| `CaptureAnnotationEditorView` | コメント・囲み・番号の注釈エディタ | `OneClip/CaptureAnnotationEditor.swift` | 使用中 |
| `CapturePermissionContent` | 画面収録の許可案内コンテンツ | `OneClip/NativeCaptureInterface.swift` | 使用中 |
| `CaptureGuideView` / `CaptureUsageGuideView` | 撮影前案内・使い方案内 | `OneClip/NativeCaptureInterface.swift` | 使用中 |
| `OneClipOnboardingView` / `OnboardingWindowDotsView` | 初回オンボーディング（全13ページ、1ページ1主張、窓ドット、称賛・触覚反応、ミニ試し操作） | `OneClip/NativeCaptureInterface.swift` | 新規（`OneClipStyle`・`ART_DIRECTION.md` 準拠） |
| `CaptureProblemView` / `CaptureFeedbackView` | 問題発生時・状態フィードバック表示 | `OneClip/NativeCaptureInterface.swift` | 使用中 |
| `CaptureDiscardConfirmationView` / `CollectionConfirmationView` | 破棄・撮り直し確認ダイアログ | `OneClip/NativeCaptureInterface.swift`, `OneClip/CollectionPanel.swift` | 使用中 |

## 主要パーツ詳細

### `OneClipTone` / `OneClipBadge` / `OneClipHeading`
- 役割：アプリ全体の色役割と画面導入の統一。
- 使う場面：各ウィンドウ・シート・カードの見出しと状態表現。
- 使わない場面：注釈エディタの描画色パレット（画像上の視認性を優先する描画色は別扱い）。
- 状態：ライト／ダークモード対応（`colorScheme`）。
- 狙い：単発（`single`）とまとめ（`collection`）を即座に区別し、静かで明晰な印象を与える。
- アート方針との対応：「3. 色の性格」「4. 形の言語（アイコンのタッチ）」「5. 文字と密度」。

### `OneClipCard` (`.oneClipCard()`) / `OneClipWindow` (`.oneClipWindow()`)
- 役割：画面と情報グループの余白・角丸・背景・境界線を統一する。
- 使う場面：設定画面、使い方案内、権限・確認ダイアログなどの標準ウィンドウとカード。
- 使わない場面：フローティング小画像（`CaptureResultView`）や注釈エディタなど、作業領域が主役の専用ウィンドウ。
- 状態：通常 ／ 高コントラスト（`colorSchemeContrast == .increased` で境界線を強調）。
- 狙い：面と余白で自然に情報を区切り、認知負荷を下げる。
- アート方針との対応：「4. 形の言語」「5. 文字と密度」。

### `CaptureResultView`
- 役割：撮影直後に右下に8秒間表示し、「コピー・保存できたこと」と「注釈追加への入口」を静かに伝える。
- 状態：通常 ／ 保存中 ／ 保存失敗（再試行・保存せず続行）。
- 狙い：作業を邪魔せず、撮った画像サムネイルを主役に見せる。
- アート方針との対応：「4. 形の言語（`.continuous` 角丸、高コントラスト境界線）」。
